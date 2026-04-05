#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/common.sh"

usage() {
    cat <<'EOF'
Usage: ./tools/run_reference_producer.sh [prepare|run|export|validate|all] [options]

Options:
  --dataset-id <id>        Override the replay dataset id.
  --run-id <id>            Override the run directory id.
  --sim-time-limit <sec>   Override the reference scenario duration. Default: 60s
  --frame-step <sec>       Override self-trigger interval. Default: 1s
  --jobs <n>               Override build parallelism.
EOF
}

ACTION="${1:-all}"
case "${ACTION}" in
    prepare|run|export|validate|all)
        shift || true
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        ACTION="all"
        ;;
esac

DATASET_ID="${DATASET_ID:-ntpu-2-endpoints-via-leo-18sat-walker-v1}"
RUN_ID="${RUN_ID:-$(date '+%Y%m%d_%H%M%S')}"
SIM_TIME_LIMIT="${SIM_TIME_LIMIT:-60s}"
FRAME_STEP="${FRAME_STEP:-1s}"
BUILD_JOBS="${BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dataset-id)
            DATASET_ID="$2"
            shift 2
            ;;
        --run-id)
            RUN_ID="$2"
            shift 2
            ;;
        --sim-time-limit)
            SIM_TIME_LIMIT="$2"
            shift 2
            ;;
        --frame-step)
            FRAME_STEP="$2"
            shift 2
            ;;
        --jobs)
            BUILD_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf "Unknown option: %s\n" "$1" >&2
            usage
            exit 1
            ;;
    esac
done

WORK_ROOT="${STATE_DIR}/reference-producer"
RUN_DIR="${WORK_ROOT}/runs/${RUN_ID}"
SCENARIO_DIR="${RUN_DIR}/scenario"
RAW_DIR="${RUN_DIR}/raw"
DATASET_DIR="${RUN_DIR}/dataset/${DATASET_ID}"
REPORT_DIR="${RUN_DIR}/reports"
SCENARIO_INI="${SCENARIO_DIR}/reference-producer.ini"
EXPORT_METADATA="${REPORT_DIR}/export-metadata.json"
VALIDATION_REPORT="${REPORT_DIR}/validation-report.json"
RUN_LOG="${LOG_DIR}/reference_producer_${RUN_ID}.log"
TLE_FILE="${ESTNET_TEMPLATE_DIR}/simulations/configs/tles/walker_o6_s3_i45_h698.tle"
TEMPLATE_BIN="${ESTNET_TEMPLATE_DIR}/out/gcc-release/src/estnet-template"
RESULT_DB=""

mkdir -p "${SCENARIO_DIR}" "${RAW_DIR}" "${DATASET_DIR}" "${REPORT_DIR}" "${LOG_DIR}"
ln -sfn "runs/${RUN_ID}" "${WORK_ROOT}/latest"

need_stage_success() {
    local stage_id="$1"
    local description="$2"
    local state_file="${STATE_DIR}/${stage_id}.state"
    if [[ ! -f "${state_file}" ]]; then
        printf "Missing stage state for %s: %s\n" "${description}" "${state_file}" >&2
        exit 1
    fi
    if ! grep -Fxq "status=success" "${state_file}"; then
        local status
        status="$(sed -n 's/^status=//p' "${state_file}" | head -n1)"
        printf "Stage %s is not successful (current: %s)\n" "${description}" "${status:-unknown}" >&2
        exit 1
    fi
}

repair_workspace_root_references() {
    local file
    for file in "${OMNETPP_DIR}/Makefile.inc" "${OMNETPP_DIR}/configure.user"; do
        [[ -f "${file}" ]] || continue
        python3 - "${file}" "${PROJECT_ROOT}" <<'PY'
from pathlib import Path
import re
import sys

file_path = Path(sys.argv[1])
project_root = str(Path(sys.argv[2]).resolve())
text = file_path.read_text(encoding="utf-8")
updated = text

prefixes = set()
for suffix in ("/third_party/install", "/omnetpp-5.5.1", "/build/omnetpp-ide"):
    pattern = re.compile(r"(/[^ \n\r\t:\"']+?)" + re.escape(suffix))
    for match in pattern.finditer(text):
        prefix = match.group(1)
        if prefix != project_root and not Path(prefix).exists():
            prefixes.add(prefix)

for prefix in sorted(prefixes, key=len, reverse=True):
    updated = updated.replace(prefix, project_root)

if updated != text:
    file_path.write_text(updated, encoding="utf-8")
    print(f"repaired {file_path}")
else:
    print(f"ok {file_path}")
PY
    done
}

prepare_reference_environment() {
    need_stage_success "50" "Stage 50 (INET build)"
    need_stage_success "60" "Stage 60 (estnet clone)"

    repair_worktree_metadata "${ESTNET_SOURCE_DIR}" "${ESTNET_DIR}" "estnet" >/dev/null 2>&1 || true
    repair_worktree_metadata "${ESTNET_TEMPLATE_SOURCE_DIR}" "${ESTNET_TEMPLATE_DIR}" "estnet_template" >/dev/null 2>&1 || true
    repair_workspace_root_references

    "${ROOT_DIR}/tools/run_stage.sh" --force 70

    (
        source "${ROOT_DIR}/activate_env.sh"
        cd "${ESTNET_DIR}/src"
        opp_makemake --make-so -f --deep -o ESTNeT -O out -pESTNET -KINET4_PROJ=../../inet -DINET_IMPORT -I. -I../../inet/src -L../../inet/src -lINET
        make MODE=release clean >/dev/null 2>&1 || true
        make MODE=release -j"${BUILD_JOBS}"
    )

    (
        source "${ROOT_DIR}/activate_env.sh"
        cd "${ESTNET_TEMPLATE_DIR}/src"
        opp_makemake -f --deep -o estnet-template -L../../estnet/out/gcc-release/src -lESTNeT -L../../inet/src -lINET
        make MODE=release clean >/dev/null 2>&1 || true
        make MODE=release -j"${BUILD_JOBS}"
    )
}

write_reference_scenario() {
    cat > "${SCENARIO_INI}" <<EOF
include ${ESTNET_TEMPLATE_DIR}/simulations/omnetpp.ini

[Config ReferenceProducer]
extends = General
sim-time-limit = ${SIM_TIME_LIMIT}
result-dir = "${RAW_DIR}"
record-eventlog = false
output-scalar-file = "${RAW_DIR}/ReferenceProducer-\${runnumber}.sca"
output-vector-file = "${RAW_DIR}/ReferenceProducer-\${runnumber}.vec"
output-vector-file-append = false
**.statistic-recording = true
**.scalar-recording = false
**.bin-recording = false
**.vector-recording = true
*.numCg = 2
*.cg[0].networkHost.mobility.lat = 24.9441667deg
*.cg[0].networkHost.mobility.lon = 121.3713889deg
*.cg[0].networkHost.mobility.alt = 51.5m
*.cg[0].label = "endpoint-a"
*.cg[1].networkHost.mobility.lat = 24.9436970deg
*.cg[1].networkHost.mobility.lon = 121.3732219deg
*.cg[1].networkHost.mobility.alt = 51.5m
*.cg[1].label = "endpoint-b"
*.sat[*].networkHost.mobility.enableSelfTrigger = true
*.sat[*].networkHost.mobility.selfTriggerTimeIv = ${FRAME_STEP}
*.cg[*].networkHost.mobility.enableSelfTrigger = true
*.cg[*].networkHost.mobility.selfTriggerTimeIv = ${FRAME_STEP}
EOF
}

run_reference_scenario() {
    write_reference_scenario
    (
        source "${ROOT_DIR}/activate_env.sh"
        cd "${ESTNET_TEMPLATE_DIR}/simulations"
        "${TEMPLATE_BIN}" \
            -u Cmdenv \
            -n .:../src:../../inet/src:../../inet/examples:../../inet/tutorials:../../inet/showcases:../../estnet/src \
            -c ReferenceProducer \
            "${SCENARIO_INI}"
    ) | tee "${RUN_LOG}"
}

export_reference_dataset() {
    RESULT_DB="$(discover_result_db)"
    python3 "${ROOT_DIR}/tools/reference_producer.py" export \
        --vector-db "${RESULT_DB}" \
        --tle-file "${TLE_FILE}" \
        --output-dir "${DATASET_DIR}" \
        --metadata-out "${EXPORT_METADATA}" \
        --scenario-ini "${SCENARIO_INI}" \
        --dataset-id "${DATASET_ID}"
}

validate_reference_dataset() {
    RESULT_DB="$(discover_result_db)"
    python3 "${ROOT_DIR}/tools/reference_producer.py" validate \
        --dataset-dir "${DATASET_DIR}" \
        --vector-db "${RESULT_DB}" \
        --scenario-ini "${SCENARIO_INI}" \
        --report-out "${VALIDATION_REPORT}"
}

discover_result_db() {
    python3 - "${RAW_DIR}" <<'PY'
from pathlib import Path
import sqlite3
import sys

raw_dir = Path(sys.argv[1])
candidates = sorted(list(raw_dir.glob("*.vec")) + list(raw_dir.glob("*.sca")))
best_candidate = None
best_vector_count = -1
for candidate in candidates:
    try:
        with sqlite3.connect(candidate) as connection:
            has_vector_data = connection.execute(
                "select 1 from sqlite_master where type='table' and name='vectorData'"
            ).fetchone()
            if not has_vector_data:
                continue
            vector_count = connection.execute("select count(*) from vector").fetchone()[0]
    except sqlite3.Error:
        continue
    if vector_count > best_vector_count:
        best_candidate = candidate
        best_vector_count = vector_count

if best_candidate is None:
    raise SystemExit(f"Could not find a SQLite result DB with vectorData under {raw_dir}")

if best_vector_count <= 0:
    raise SystemExit(f"Found SQLite result DBs under {raw_dir}, but none contain recorded vectors")

print(best_candidate)
PY
}

case "${ACTION}" in
    prepare)
        prepare_reference_environment
        ;;
    run)
        prepare_reference_environment
        run_reference_scenario
        ;;
    export)
        export_reference_dataset
        ;;
    validate)
        validate_reference_dataset
        ;;
    all)
        prepare_reference_environment
        run_reference_scenario
        export_reference_dataset
        validate_reference_dataset
        ;;
esac

printf "reference_producer.run_id=%s\n" "${RUN_ID}"
printf "reference_producer.dataset_id=%s\n" "${DATASET_ID}"
printf "reference_producer.result_db=%s\n" "${RESULT_DB:-not-resolved}"
printf "reference_producer.dataset_dir=%s\n" "${DATASET_DIR}"
printf "reference_producer.validation_report=%s\n" "${VALIDATION_REPORT}"
