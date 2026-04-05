#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import re
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


PACKAGE_VERSION = "EstnetReplayPackageV1"
FRAME_SCHEMA_VERSION = "EstnetLocalSceneFrameV1"
SCENARIO_ID = "ntpu-2-endpoints-via-leo"
SCENE_ID = "ntpu-local"
COORDINATE_FRAME = "ntpu-local-enu-v1"
SIMTIME_RAW_PER_SEC = 1_000_000_000_000
TLE_YEAR_SPLIT = 57
DEFAULT_ROUND_DIGITS = 3
DEFAULT_MAPPING_TOLERANCE_M = 1.0

ANCHOR_LAT_DEG = 24.9441667
ANCHOR_LON_DEG = 121.3713889
ANCHOR_ALT_M = 50.0

EXPECTED_ENDPOINT_POSITIONS = {
    "endpoint-a": [0.0, 0.0, 1.5],
    "endpoint-b": [185.0, -52.0, 1.5],
}

WGS84_A = 6378137.0
WGS84_F = 1 / 298.257223563
WGS84_E2 = WGS84_F * (2 - WGS84_F)

SATELLITE_MODULE_RE = re.compile(
    r"^SpaceTerrestrialNetwork\.sat\[(?P<index>\d+)\]\.networkHost\.mobility$"
)
GROUND_PARAM_RE = re.compile(
    r"^\*\.cg\[(?P<index>\d+)\]\.networkHost\.mobility\.(?P<field>lat|lon|alt)$"
)
GROUND_LABEL_RE = re.compile(r'^\*\.cg\[(?P<index>\d+)\]\.label$')
GROUND_MODULE_RE = re.compile(
    r"^SpaceTerrestrialNetwork\.cg\[(?P<index>\d+)\]\.networkHost\.mobility$"
)


class ProducerError(RuntimeError):
    pass


@dataclass(frozen=True)
class GroundNodeConfig:
    native_index: int
    native_label: str
    latitude_deg: float
    longitude_deg: float
    altitude_m: float


def json_dump(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def strip_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def parse_degree_value(value: str) -> float:
    cleaned = strip_quotes(value).strip()
    if cleaned.endswith("deg"):
        cleaned = cleaned[:-3]
    return float(cleaned)


def parse_meter_value(value: str) -> float:
    cleaned = strip_quotes(value).strip()
    if cleaned.endswith("m"):
        cleaned = cleaned[:-1]
    return float(cleaned)


def round_coord(values: Iterable[float], digits: int) -> list[float]:
    return [round(value, digits) for value in values]


def parse_tle_epoch(tle_path: Path) -> float:
    lines = [line.rstrip("\n") for line in tle_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(lines) < 2:
        raise ProducerError(f"TLE file is missing standard line records: {tle_path}")
    line1 = lines[1]
    if len(line1) < 32:
        raise ProducerError(f"TLE line 1 is too short to parse epoch: {tle_path}")
    tle_year = int(line1[18:20])
    year = 2000 + tle_year if tle_year < TLE_YEAR_SPLIT else 1900 + tle_year
    day_of_year = float(line1[20:32])
    return julian_from_year_day(year, day_of_year)


def julian_from_year_day(year: int, day_of_year: float) -> float:
    year_minus_one = year - 1
    century = year_minus_one // 100
    correction = 2 - century + century // 4
    new_years = int(365.25 * year_minus_one) + int(30.6001 * 14) + 1720994.5 + correction
    return new_years + day_of_year


def gmst_radians_from_julian(julian_date: float) -> float:
    ut = math.fmod(julian_date + 0.5, 1.0)
    tu = ((julian_date - 2451545.0) - ut) / 36525.0
    gmst_seconds = 24110.54841 + tu * (8640184.812866 + tu * (0.093104 - tu * 6.2e-06))
    gmst_seconds = math.fmod(gmst_seconds + 86400.0 * 1.00273790934 * ut, 86400.0)
    if gmst_seconds < 0:
        gmst_seconds += 86400.0
    return 2 * math.pi * (gmst_seconds / 86400.0)


def geodetic_to_ecef(latitude_deg: float, longitude_deg: float, altitude_m: float) -> tuple[float, float, float]:
    latitude_rad = math.radians(latitude_deg)
    longitude_rad = math.radians(longitude_deg)
    n = WGS84_A / math.sqrt(1 - WGS84_E2 * math.sin(latitude_rad) ** 2)
    x = (n + altitude_m) * math.cos(latitude_rad) * math.cos(longitude_rad)
    y = (n + altitude_m) * math.cos(latitude_rad) * math.sin(longitude_rad)
    z = (n * (1 - WGS84_E2) + altitude_m) * math.sin(latitude_rad)
    return x, y, z


def ecef_to_geodetic(x: float, y: float, z: float) -> tuple[float, float, float]:
    longitude = math.atan2(y, x)
    p = math.hypot(x, y)
    latitude = math.atan2(z, p * (1 - WGS84_E2))
    altitude = 0.0
    for _ in range(8):
        n = WGS84_A / math.sqrt(1 - WGS84_E2 * math.sin(latitude) ** 2)
        altitude = p / math.cos(latitude) - n
        latitude = math.atan2(z, p * (1 - WGS84_E2 * n / (n + altitude)))
    n = WGS84_A / math.sqrt(1 - WGS84_E2 * math.sin(latitude) ** 2)
    altitude = p / math.cos(latitude) - n
    return math.degrees(latitude), math.degrees(longitude), altitude


def eci_to_ecef(x: float, y: float, z: float, julian_date: float) -> tuple[float, float, float]:
    theta = gmst_radians_from_julian(julian_date)
    x_ecef = math.cos(theta) * x + math.sin(theta) * y
    y_ecef = -math.sin(theta) * x + math.cos(theta) * y
    return x_ecef, y_ecef, z


def project_ecef_to_enu(
    x: float,
    y: float,
    z: float,
    anchor_lat_deg: float,
    anchor_lon_deg: float,
    anchor_alt_m: float,
) -> tuple[float, float, float]:
    anchor_x, anchor_y, anchor_z = geodetic_to_ecef(anchor_lat_deg, anchor_lon_deg, anchor_alt_m)
    anchor_lat_rad = math.radians(anchor_lat_deg)
    anchor_lon_rad = math.radians(anchor_lon_deg)
    dx = x - anchor_x
    dy = y - anchor_y
    dz = z - anchor_z
    east = -math.sin(anchor_lon_rad) * dx + math.cos(anchor_lon_rad) * dy
    north = (
        -math.sin(anchor_lat_rad) * math.cos(anchor_lon_rad) * dx
        - math.sin(anchor_lat_rad) * math.sin(anchor_lon_rad) * dy
        + math.cos(anchor_lat_rad) * dz
    )
    up = (
        math.cos(anchor_lat_rad) * math.cos(anchor_lon_rad) * dx
        + math.cos(anchor_lat_rad) * math.sin(anchor_lon_rad) * dy
        + math.sin(anchor_lat_rad) * dz
    )
    return east, north, up


def project_geodetic_to_enu(
    latitude_deg: float,
    longitude_deg: float,
    altitude_m: float,
    anchor_lat_deg: float,
    anchor_lon_deg: float,
    anchor_alt_m: float,
) -> tuple[float, float, float]:
    x, y, z = geodetic_to_ecef(latitude_deg, longitude_deg, altitude_m)
    return project_ecef_to_enu(x, y, z, anchor_lat_deg, anchor_lon_deg, anchor_alt_m)


def project_eci_to_enu(
    x: float,
    y: float,
    z: float,
    sim_time_sec: float,
    base_julian_date: float,
    anchor_lat_deg: float,
    anchor_lon_deg: float,
    anchor_alt_m: float,
) -> tuple[float, float, float]:
    julian_date = base_julian_date + sim_time_sec / 86400.0
    ecef_x, ecef_y, ecef_z = eci_to_ecef(x, y, z, julian_date)
    return project_ecef_to_enu(ecef_x, ecef_y, ecef_z, anchor_lat_deg, anchor_lon_deg, anchor_alt_m)


def load_run_params(connection: sqlite3.Connection) -> dict[str, str]:
    cursor = connection.cursor()
    params: dict[str, str] = {}
    for key, value, _order in cursor.execute(
        "select paramKey, paramValue, paramOrder from runParam order by paramOrder"
    ):
        params[key] = value
    return params


def parse_assignment_file(path: Path) -> dict[str, str]:
    assignments: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        assignments[key.strip()] = value.strip()
    return assignments


def load_ground_nodes(run_params: dict[str, str]) -> list[GroundNodeConfig]:
    ground_nodes: dict[int, dict[str, Any]] = {}
    for key, value in run_params.items():
        field_match = GROUND_PARAM_RE.match(key)
        if field_match:
            index = int(field_match.group("index"))
            field = field_match.group("field")
            record = ground_nodes.setdefault(index, {"native_index": index})
            if field == "lat":
                record["latitude_deg"] = parse_degree_value(value)
            elif field == "lon":
                record["longitude_deg"] = parse_degree_value(value)
            elif field == "alt":
                record["altitude_m"] = parse_meter_value(value)
            continue

        label_match = GROUND_LABEL_RE.match(key)
        if label_match:
            index = int(label_match.group("index"))
            record = ground_nodes.setdefault(index, {"native_index": index})
            record["native_label"] = strip_quotes(value)

    parsed_nodes: list[GroundNodeConfig] = []
    for index in sorted(ground_nodes):
        record = ground_nodes[index]
        missing = [field for field in ("native_label", "latitude_deg", "longitude_deg", "altitude_m") if field not in record]
        if missing:
            raise ProducerError(f"Ground node cg[{index}] is missing required runParam fields: {', '.join(missing)}")
        parsed_nodes.append(GroundNodeConfig(**record))
    return parsed_nodes


def discover_satellite_modules(connection: sqlite3.Connection) -> list[tuple[int, str]]:
    cursor = connection.cursor()
    modules: list[tuple[int, str]] = []
    for (module_name,) in cursor.execute(
        "select distinct moduleName from vector where moduleName like 'SpaceTerrestrialNetwork.sat[%].networkHost.mobility' order by moduleName"
    ):
        match = SATELLITE_MODULE_RE.match(module_name)
        if not match:
            continue
        modules.append((int(match.group("index")), module_name))
    if not modules:
        raise ProducerError("Could not find any satellite mobility vector modules in the OMNeT++ result database.")
    return sorted(modules, key=lambda item: item[0])


def discover_ground_modules(connection: sqlite3.Connection) -> list[tuple[int, str]]:
    cursor = connection.cursor()
    modules: list[tuple[int, str]] = []
    for (module_name,) in cursor.execute(
        "select distinct moduleName from vector where moduleName like 'SpaceTerrestrialNetwork.cg[%].networkHost.mobility' order by moduleName"
    ):
        match = GROUND_MODULE_RE.match(module_name)
        if not match:
            continue
        modules.append((int(match.group("index")), module_name))
    return sorted(modules, key=lambda item: item[0])


def load_series(connection: sqlite3.Connection, module_name: str, vector_name: str) -> list[tuple[int, float]]:
    cursor = connection.cursor()
    row = cursor.execute(
        "select vectorId from vector where moduleName = ? and vectorName = ?",
        (module_name, vector_name),
    ).fetchone()
    if row is None:
        raise ProducerError(f"Missing vector '{vector_name}' for module '{module_name}'.")
    vector_id = row[0]
    return [
        (int(simtime_raw), float(value))
        for simtime_raw, value in cursor.execute(
            "select simtimeRaw, value from vectorData where vectorId = ? order by simtimeRaw",
            (vector_id,),
        )
    ]


def aligned_axis_series(
    connection: sqlite3.Connection,
    module_name: str,
) -> tuple[list[int], list[float], list[float], list[float]]:
    x_series = load_series(connection, module_name, "eciPositionX:vector")
    y_series = load_series(connection, module_name, "eciPositionY:vector")
    z_series = load_series(connection, module_name, "eciPositionZ:vector")
    if not x_series:
        raise ProducerError(f"Module '{module_name}' does not contain any mobility samples.")
    if len(x_series) != len(y_series) or len(x_series) != len(z_series):
        raise ProducerError(f"Module '{module_name}' has mismatched vector lengths across X/Y/Z ECI series.")

    timestamps = [item[0] for item in x_series]
    if timestamps != [item[0] for item in y_series] or timestamps != [item[0] for item in z_series]:
        raise ProducerError(f"Module '{module_name}' has mismatched timestamps across X/Y/Z ECI series.")

    return (
        timestamps,
        [item[1] for item in x_series],
        [item[1] for item in y_series],
        [item[1] for item in z_series],
    )


def satellite_id_from_index(index: int) -> str:
    return f"sat-{index + 1:02d}"


def build_export_metadata(
    vector_db: Path,
    tle_file: Path,
    frame_count: int,
    first_frame_id: int,
    last_frame_id: int,
    frame_step_sec: float,
    ground_nodes: list[GroundNodeConfig],
    satellite_modules: list[tuple[int, str]],
    round_digits: int,
) -> dict[str, Any]:
    ground_node_entries = []
    for node in ground_nodes:
        projected = round_coord(
            project_geodetic_to_enu(
                node.latitude_deg,
                node.longitude_deg,
                node.altitude_m,
                ANCHOR_LAT_DEG,
                ANCHOR_LON_DEG,
                ANCHOR_ALT_M,
            ),
            round_digits,
        )
        ground_node_entries.append(
            {
                "nativeIndex": node.native_index,
                "nativeLabel": node.native_label,
                "latitudeDeg": node.latitude_deg,
                "longitudeDeg": node.longitude_deg,
                "altitudeM": node.altitude_m,
                "projectedPositionEnuM": projected,
            }
        )

    return {
        "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "datasetContract": {
            "packageVersion": PACKAGE_VERSION,
            "frameSchemaVersion": FRAME_SCHEMA_VERSION,
            "scenarioId": SCENARIO_ID,
            "sceneId": SCENE_ID,
            "coordinateFrame": COORDINATE_FRAME,
        },
        "sourceVectorDb": str(vector_db),
        "sourceTleFile": str(tle_file),
        "anchor": {
            "latitudeDeg": ANCHOR_LAT_DEG,
            "longitudeDeg": ANCHOR_LON_DEG,
            "altitudeM": ANCHOR_ALT_M,
        },
        "frames": {
            "frameCount": frame_count,
            "firstFrameId": first_frame_id,
            "lastFrameId": last_frame_id,
            "frameStepSec": frame_step_sec,
        },
        "groundNodes": ground_node_entries,
        "satellites": [
            {
                "nativeIndex": native_index,
                "nativeModule": module_name,
                "satelliteId": satellite_id_from_index(native_index),
            }
            for native_index, module_name in satellite_modules
        ],
    }


def command_export(args: argparse.Namespace) -> int:
    vector_db = Path(args.vector_db).resolve()
    output_dir = Path(args.output_dir).resolve()
    metadata_out = Path(args.metadata_out).resolve() if args.metadata_out else None
    tle_file = Path(args.tle_file).resolve()

    if not vector_db.is_file():
        raise ProducerError(f"Result database is missing: {vector_db}")
    if not tle_file.is_file():
        raise ProducerError(f"TLE file is missing: {tle_file}")

    output_dir.mkdir(parents=True, exist_ok=True)
    frames_dir = output_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)

    base_julian_date = parse_tle_epoch(tle_file)
    scenario_assignments = parse_assignment_file(Path(args.scenario_ini).resolve()) if args.scenario_ini else None

    with sqlite3.connect(vector_db) as connection:
        run_params = load_run_params(connection)
        ground_nodes = load_ground_nodes(scenario_assignments or run_params)
        satellite_modules = discover_satellite_modules(connection)

        if len(satellite_modules) != args.satellite_count:
            raise ProducerError(
                f"Expected {args.satellite_count} satellite mobility modules, found {len(satellite_modules)}."
            )

        reference_timestamps: list[int] | None = None
        series_by_satellite: dict[int, tuple[list[float], list[float], list[float]]] = {}

        for native_index, module_name in satellite_modules:
            timestamps, xs, ys, zs = aligned_axis_series(connection, module_name)
            if reference_timestamps is None:
                reference_timestamps = timestamps
            elif reference_timestamps != timestamps:
                raise ProducerError(
                    f"Satellite module '{module_name}' does not share the same timestamp grid as the first satellite."
                )
            series_by_satellite[native_index] = (xs, ys, zs)

    if reference_timestamps is None or not reference_timestamps:
        raise ProducerError("No mobility timestamps were available for replay export.")

    first_frame_id = args.first_frame_id
    last_frame_id = first_frame_id + len(reference_timestamps) - 1

    frame_step_sec = 0.0
    if len(reference_timestamps) > 1:
        frame_step_sec = (reference_timestamps[1] - reference_timestamps[0]) / SIMTIME_RAW_PER_SEC

    manifest = {
        "packageVersion": PACKAGE_VERSION,
        "datasetId": args.dataset_id,
        "scenarioId": SCENARIO_ID,
        "sceneId": SCENE_ID,
        "coordinateFrame": COORDINATE_FRAME,
        "frameSchemaVersion": FRAME_SCHEMA_VERSION,
        "frameDirectory": "frames",
        "frameFileDigits": args.frame_file_digits,
        "firstFrameId": first_frame_id,
        "lastFrameId": last_frame_id,
        "frameCount": len(reference_timestamps),
        "satelliteCount": args.satellite_count,
        "endpointIds": args.endpoint_ids,
        "playbackDefaults": {
            "autoplay": False,
            "loop": True,
            "targetFps": args.playback_target_fps,
            "startFrameId": first_frame_id,
        },
    }
    json_dump(output_dir / "manifest.json", manifest)

    for offset, simtime_raw in enumerate(reference_timestamps):
        frame_id = first_frame_id + offset
        sim_time_sec = simtime_raw / SIMTIME_RAW_PER_SEC
        satellites = []
        for native_index, _module_name in satellite_modules:
            xs, ys, zs = series_by_satellite[native_index]
            enu = project_eci_to_enu(
                xs[offset],
                ys[offset],
                zs[offset],
                sim_time_sec,
                base_julian_date,
                ANCHOR_LAT_DEG,
                ANCHOR_LON_DEG,
                ANCHOR_ALT_M,
            )
            satellites.append(
                {
                    "id": satellite_id_from_index(native_index),
                    "positionEnuM": round_coord(enu, args.round_digits),
                }
            )

        frame_payload = {
            "schemaVersion": FRAME_SCHEMA_VERSION,
            "scenarioId": SCENARIO_ID,
            "sceneId": SCENE_ID,
            "frameId": frame_id,
            "simTimeSec": round(sim_time_sec, args.round_digits),
            "satellites": satellites,
        }
        json_dump(frames_dir / f"frame-{frame_id:0{args.frame_file_digits}d}.json", frame_payload)

    if metadata_out is not None:
        metadata = build_export_metadata(
            vector_db=vector_db,
            tle_file=tle_file,
            frame_count=len(reference_timestamps),
            first_frame_id=first_frame_id,
            last_frame_id=last_frame_id,
            frame_step_sec=frame_step_sec,
            ground_nodes=ground_nodes,
            satellite_modules=satellite_modules,
            round_digits=args.round_digits,
        )
        json_dump(metadata_out, metadata)

    return 0


def add_blocker(blockers: list[dict[str, str]], category: str, message: str) -> None:
    blockers.append({"category": category, "message": message})


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_manifest(manifest: dict[str, Any], dataset_dir: Path) -> list[str]:
    errors: list[str] = []

    required = {
        "packageVersion": PACKAGE_VERSION,
        "scenarioId": SCENARIO_ID,
        "sceneId": SCENE_ID,
        "coordinateFrame": COORDINATE_FRAME,
        "frameSchemaVersion": FRAME_SCHEMA_VERSION,
        "frameDirectory": "frames",
        "frameFileDigits": 6,
    }
    for field, expected in required.items():
        actual = manifest.get(field)
        if actual != expected:
            errors.append(f"manifest.{field} expected {expected!r} but found {actual!r}")

    if manifest.get("datasetId") != dataset_dir.name:
        errors.append(
            f"manifest.datasetId expected to match dataset directory name {dataset_dir.name!r}, found {manifest.get('datasetId')!r}"
        )

    first_frame_id = manifest.get("firstFrameId")
    last_frame_id = manifest.get("lastFrameId")
    frame_count = manifest.get("frameCount")
    if not isinstance(first_frame_id, int) or not isinstance(last_frame_id, int) or not isinstance(frame_count, int):
        errors.append("manifest frame range fields must all be integers")
    elif frame_count != (last_frame_id - first_frame_id + 1):
        errors.append("manifest.frameCount does not match first/last frame range")

    if manifest.get("satelliteCount") != 18:
        errors.append(f"manifest.satelliteCount expected 18 but found {manifest.get('satelliteCount')!r}")

    if manifest.get("endpointIds") != ["endpoint-a", "endpoint-b"]:
        errors.append(f"manifest.endpointIds expected ['endpoint-a', 'endpoint-b'] but found {manifest.get('endpointIds')!r}")

    playback_defaults = manifest.get("playbackDefaults")
    if not isinstance(playback_defaults, dict):
        errors.append("manifest.playbackDefaults must be an object")

    return errors


def validate_frames(manifest: dict[str, Any], dataset_dir: Path) -> tuple[list[str], dict[str, Any]]:
    errors: list[str] = []
    first_frame_id = manifest["firstFrameId"]
    last_frame_id = manifest["lastFrameId"]
    frame_digits = manifest["frameFileDigits"]
    frame_dir = dataset_dir / manifest["frameDirectory"]
    expected_satellite_count = manifest["satelliteCount"]
    satellite_ids_reference: list[str] | None = None
    frame_metrics: dict[str, Any] = {
        "frameCount": 0,
        "firstSimTimeSec": None,
        "lastSimTimeSec": None,
        "satelliteIds": [],
    }

    for frame_id in range(first_frame_id, last_frame_id + 1):
        frame_path = frame_dir / f"frame-{frame_id:0{frame_digits}d}.json"
        if not frame_path.is_file():
            errors.append(f"missing frame file: {frame_path}")
            continue
        frame = load_json(frame_path)
        if frame.get("schemaVersion") != FRAME_SCHEMA_VERSION:
            errors.append(f"{frame_path.name}: schemaVersion mismatch")
        if frame.get("scenarioId") != SCENARIO_ID:
            errors.append(f"{frame_path.name}: scenarioId mismatch")
        if frame.get("sceneId") != SCENE_ID:
            errors.append(f"{frame_path.name}: sceneId mismatch")
        if frame.get("frameId") != frame_id:
            errors.append(f"{frame_path.name}: frameId does not match file name")
        if not isinstance(frame.get("simTimeSec"), (int, float)):
            errors.append(f"{frame_path.name}: simTimeSec must be numeric")

        satellites = frame.get("satellites")
        if not isinstance(satellites, list):
            errors.append(f"{frame_path.name}: satellites must be an array")
            continue
        if len(satellites) != expected_satellite_count:
            errors.append(
                f"{frame_path.name}: expected {expected_satellite_count} satellites but found {len(satellites)}"
            )

        current_satellite_ids: list[str] = []
        for satellite in satellites:
            satellite_id = satellite.get("id")
            position = satellite.get("positionEnuM")
            if not isinstance(satellite_id, str):
                errors.append(f"{frame_path.name}: satellite id must be a string")
                continue
            if not isinstance(position, list) or len(position) != 3:
                errors.append(f"{frame_path.name}: satellite {satellite_id} must provide a 3-element positionEnuM array")
                continue
            if not all(isinstance(component, (int, float)) and math.isfinite(component) for component in position):
                errors.append(f"{frame_path.name}: satellite {satellite_id} has non-finite ENU coordinates")
                continue
            current_satellite_ids.append(satellite_id)

        if satellite_ids_reference is None:
            satellite_ids_reference = current_satellite_ids
        elif satellite_ids_reference != current_satellite_ids:
            errors.append(f"{frame_path.name}: satellite id ordering is not stable across frames")

        frame_metrics["frameCount"] += 1
        frame_metrics["firstSimTimeSec"] = frame["simTimeSec"] if frame_metrics["firstSimTimeSec"] is None else frame_metrics["firstSimTimeSec"]
        frame_metrics["lastSimTimeSec"] = frame["simTimeSec"]

    if satellite_ids_reference is not None:
        frame_metrics["satelliteIds"] = satellite_ids_reference

    return errors, frame_metrics


def validate_reference_scenario(
    scenario_params: dict[str, str],
    ground_nodes: list[GroundNodeConfig],
    ground_module_indices: set[int],
    tolerance_m: float,
) -> tuple[list[str], list[dict[str, Any]]]:
    errors: list[str] = []
    if scenario_params.get("*.numCg") != "2":
        errors.append(f"scenario *.numCg expected '2' but found {scenario_params.get('*.numCg')!r}")

    mapping_entries: list[dict[str, Any]] = []
    labels = {node.native_label for node in ground_nodes}
    for expected_label in ("endpoint-a", "endpoint-b"):
        if expected_label not in labels:
            errors.append(f"reference scenario is missing native ground node label {expected_label!r} in scenario ini")

    for node in ground_nodes:
        if node.native_index not in ground_module_indices:
            errors.append(
                f"native ground node cg[{node.native_index}] from scenario ini was not instantiated with recorded mobility vectors"
            )
        expected_position = EXPECTED_ENDPOINT_POSITIONS.get(node.native_label)
        projected = project_geodetic_to_enu(
            node.latitude_deg,
            node.longitude_deg,
            node.altitude_m,
            ANCHOR_LAT_DEG,
            ANCHOR_LON_DEG,
            ANCHOR_ALT_M,
        )
        delta = [
            projected[0] - expected_position[0] if expected_position else None,
            projected[1] - expected_position[1] if expected_position else None,
            projected[2] - expected_position[2] if expected_position else None,
        ]
        within_tolerance = bool(
            expected_position
            and all(abs(component) <= tolerance_m for component in delta if component is not None)
        )
        if expected_position and not within_tolerance:
            errors.append(
                f"native ground node {node.native_label!r} does not project close enough to the frozen endpoint registry (tolerance {tolerance_m} m)"
            )
        mapping_entries.append(
            {
                "nativeIndex": node.native_index,
                "nativeLabel": node.native_label,
                "mappedEndpointId": node.native_label if expected_position else None,
                "configuredGeodetic": {
                    "latitudeDeg": node.latitude_deg,
                    "longitudeDeg": node.longitude_deg,
                    "altitudeM": node.altitude_m,
                },
                "projectedPositionEnuM": round_coord(projected, DEFAULT_ROUND_DIGITS),
                "expectedPositionEnuM": expected_position,
                "deltaEnuM": round_coord(
                    [component for component in delta if component is not None],
                    DEFAULT_ROUND_DIGITS,
                )
                if expected_position
                else None,
                "withinTolerance": within_tolerance,
            }
        )

    return errors, mapping_entries


def command_validate(args: argparse.Namespace) -> int:
    dataset_dir = Path(args.dataset_dir).resolve()
    report_out = Path(args.report_out).resolve() if args.report_out else None

    if not dataset_dir.is_dir():
        raise ProducerError(f"Dataset directory is missing: {dataset_dir}")

    blockers: list[dict[str, str]] = []
    manifest_path = dataset_dir / "manifest.json"
    if not manifest_path.is_file():
        raise ProducerError(f"Dataset manifest is missing: {manifest_path}")

    manifest = load_json(manifest_path)
    manifest_errors = validate_manifest(manifest, dataset_dir)
    if manifest_errors:
        for message in manifest_errors:
            add_blocker(blockers, "exporter hook", message)

    frame_errors, frame_metrics = validate_frames(manifest, dataset_dir)
    if frame_errors:
        for message in frame_errors:
            add_blocker(blockers, "exporter hook", message)

    mapping_entries: list[dict[str, Any]] = []
    scenario_errors: list[str] = []
    vector_db = Path(args.vector_db).resolve() if args.vector_db else None
    scenario_ini = Path(args.scenario_ini).resolve() if args.scenario_ini else None

    if scenario_ini is not None and not scenario_ini.is_file():
        raise ProducerError(f"Scenario ini is missing for mapping validation: {scenario_ini}")

    if vector_db is not None:
        if not vector_db.is_file():
            raise ProducerError(f"Result database is missing for mapping validation: {vector_db}")
        with sqlite3.connect(vector_db) as connection:
            run_params = load_run_params(connection)
            ground_module_indices = {index for index, _ in discover_ground_modules(connection)}
        scenario_params = parse_assignment_file(scenario_ini) if scenario_ini is not None else run_params
        ground_nodes = load_ground_nodes(scenario_params)
        scenario_errors, mapping_entries = validate_reference_scenario(
            scenario_params,
            ground_nodes,
            ground_module_indices,
            args.mapping_tolerance_m,
        )
        for message in scenario_errors:
            add_blocker(blockers, "scenario/config", message)

    report = {
        "validatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "datasetId": manifest.get("datasetId"),
        "datasetDir": str(dataset_dir),
        "packageValid": not manifest_errors and not frame_errors,
        "mappingValidated": vector_db is not None,
        "mappingValid": vector_db is not None and not scenario_errors,
        "goldenDatasetReady": not blockers and vector_db is not None,
        "blockers": blockers,
        "contractSummary": {
            "packageVersion": manifest.get("packageVersion"),
            "frameSchemaVersion": manifest.get("frameSchemaVersion"),
            "scenarioId": manifest.get("scenarioId"),
            "sceneId": manifest.get("sceneId"),
            "coordinateFrame": manifest.get("coordinateFrame"),
            "frameCount": manifest.get("frameCount"),
            "satelliteCount": manifest.get("satelliteCount"),
            "endpointIds": manifest.get("endpointIds"),
        },
        "frameMetrics": frame_metrics,
        "mappingValidation": {
            "method": "Read cg[0]/cg[1] identity and geodetic placement from the generated scenario ini, then confirm the same native ground modules were instantiated with mobility vectors and project their configured positions into the frozen ntpu-local-enu-v1 anchor.",
            "toleranceM": args.mapping_tolerance_m,
            "entries": mapping_entries,
        },
    }

    if report_out is not None:
        json_dump(report_out, report)

    if blockers:
        print(json.dumps(report, indent=2, ensure_ascii=True))
        return 2

    print(json.dumps(report, indent=2, ensure_ascii=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Replay export and validation helpers for the ESTNeT reference producer path.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export", help="Export an OMNeT++ SQLite vector database into the frozen replay package contract.")
    export_parser.add_argument("--vector-db", required=True)
    export_parser.add_argument("--tle-file", required=True)
    export_parser.add_argument("--output-dir", required=True)
    export_parser.add_argument("--metadata-out")
    export_parser.add_argument("--scenario-ini")
    export_parser.add_argument("--dataset-id", required=True)
    export_parser.add_argument("--first-frame-id", type=int, default=1)
    export_parser.add_argument("--frame-file-digits", type=int, default=6)
    export_parser.add_argument("--satellite-count", type=int, default=18)
    export_parser.add_argument("--playback-target-fps", type=int, default=10)
    export_parser.add_argument("--round-digits", type=int, default=DEFAULT_ROUND_DIGITS)
    export_parser.add_argument("--endpoint-ids", nargs="+", default=["endpoint-a", "endpoint-b"])
    export_parser.set_defaults(func=command_export)

    validate_parser = subparsers.add_parser("validate", help="Validate an exported replay package and producer-side endpoint mapping assumptions.")
    validate_parser.add_argument("--dataset-dir", required=True)
    validate_parser.add_argument("--vector-db")
    validate_parser.add_argument("--scenario-ini")
    validate_parser.add_argument("--report-out")
    validate_parser.add_argument("--mapping-tolerance-m", type=float, default=DEFAULT_MAPPING_TOLERANCE_M)
    validate_parser.set_defaults(func=command_validate)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ProducerError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
