#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "60" "clone_estnet"
trap 'handle_unexpected_error $? ${LINENO} "${BASH_COMMAND}"' ERR

if stage_should_skip; then
    exit 0
fi

stage_begin_work

need_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        stage_mark_failure "Required command '${cmd}' is missing. Install package '${pkg}' and rerun Stage 60."
    fi
}

need_stage_success() {
    local stage_id="$1"
    local description="$2"
    local state_file="${STATE_DIR}/${stage_id}.state"
    if [[ ! -f "${state_file}" ]]; then
        stage_mark_failure "${description} has not been run yet. Missing state file: ${state_file}"
    fi
    if ! grep -Fxq "status=success" "${state_file}"; then
        local status
        status="$(sed -n 's/^status=//p' "${state_file}" | head -n1)"
        stage_mark_failure "${description} is not in success state (current: ${status:-unknown}). Resolve that stage first."
    fi
}

ensure_estnet_template_time_reference() {
    local template_dir="$1"
    local orbit_uwe3="${template_dir}/simulations/configs/orbit_uwe3.incl"
    local orbit_walker="${template_dir}/simulations/configs/orbit_18sat_walker.incl"

    python3 - "${orbit_uwe3}" "${orbit_walker}" <<'PY'
from pathlib import Path
import sys

files = [
    (Path(sys.argv[1]), '*.sat[*].networkHost.mobility.positionPropagator.tleFile = "./configs/tles/UWE3.tle"', '*.globalJulianDate.tleFile = "./configs/tles/UWE3.tle"'),
    (Path(sys.argv[2]), '*.sat[*].networkHost.mobility.positionPropagator.tleFile = "./configs/tles/walker_o6_s3_i45_h698.tle"', '*.globalJulianDate.tleFile = "./configs/tles/walker_o6_s3_i45_h698.tle"'),
]

for path, anchor, expected in files:
    text = path.read_text(encoding="utf-8")
    if expected in text:
        continue
    if anchor not in text:
        raise SystemExit(f"anchor not found in {path}: {anchor}")
    replacement = anchor + "\n" + expected
    path.write_text(text.replace(anchor, replacement, 1), encoding="utf-8")
PY
}

prepare_worktree() {
    local source_dir="$1"
    local target_dir="$2"
    local commit="$3"
    local label="$4"

    if [[ -d "${target_dir}" ]]; then
        append_summary "${label}.workspace_origin=existing_dir"
        log INFO "Using existing ${label} workspace directory at ${target_dir}"
    else
        git -C "${source_dir}" worktree add --detach "${target_dir}" "${commit}"
        append_summary "${label}.workspace_origin=git_worktree_from_pinned_source"
        append_summary "${label}.worktree_source=${source_dir}"
        log INFO "Created ${label} workspace worktree at ${target_dir}"
    fi
}

need_command "git" "git"
need_command "grep" "grep"

need_stage_success "50" "Stage 50 (INET build)"

if [[ ! -d "${ESTNET_SOURCE_DIR}/.git" ]]; then
    stage_mark_failure "Pinned estnet source mirror is missing at ${ESTNET_SOURCE_DIR}. Run Stage 10 first."
fi
if [[ ! -d "${ESTNET_TEMPLATE_SOURCE_DIR}/.git" ]]; then
    stage_mark_failure "Pinned estnet-template source mirror is missing at ${ESTNET_TEMPLATE_SOURCE_DIR}. Run Stage 10 first."
fi

if [[ "$(git -C "${ESTNET_SOURCE_DIR}" rev-parse HEAD)" != "${ESTNET_COMMIT}" ]]; then
    stage_mark_failure "estnet source mirror at ${ESTNET_SOURCE_DIR} is not pinned to ${ESTNET_COMMIT}. Re-run Stage 10."
fi
if [[ "$(git -C "${ESTNET_TEMPLATE_SOURCE_DIR}" rev-parse HEAD)" != "${ESTNET_TEMPLATE_COMMIT}" ]]; then
    stage_mark_failure "estnet-template source mirror at ${ESTNET_TEMPLATE_SOURCE_DIR} is not pinned to ${ESTNET_TEMPLATE_COMMIT}. Re-run Stage 10."
fi

append_summary "estnet.repo=${ESTNET_REPO_URL}"
append_summary "estnet.ref=${ESTNET_REF}"
append_summary "estnet.commit=${ESTNET_COMMIT}"
append_summary "estnet.source_dir=${ESTNET_SOURCE_DIR}"
append_summary "estnet.target_dir=${ESTNET_DIR}"
append_summary "estnet_template.repo=${ESTNET_TEMPLATE_REPO_URL}"
append_summary "estnet_template.ref=${ESTNET_TEMPLATE_REF}"
append_summary "estnet_template.commit=${ESTNET_TEMPLATE_COMMIT}"
append_summary "estnet_template.source_dir=${ESTNET_TEMPLATE_SOURCE_DIR}"
append_summary "estnet_template.target_dir=${ESTNET_TEMPLATE_DIR}"
append_summary "estnet_template.patch.time_ref=${ESTNET_TEMPLATE_09_TIME_REF_PATCH}"

set_checkpoint "workspace" "preparing estnet worktrees"
prepare_worktree "${ESTNET_SOURCE_DIR}" "${ESTNET_DIR}" "${ESTNET_COMMIT}" "estnet"
prepare_worktree "${ESTNET_TEMPLATE_SOURCE_DIR}" "${ESTNET_TEMPLATE_DIR}" "${ESTNET_TEMPLATE_COMMIT}" "estnet_template"

if repair_worktree_metadata "${ESTNET_SOURCE_DIR}" "${ESTNET_DIR}" "estnet"; then
    append_summary "estnet.workspace_repaired=yes"
else
    append_summary "estnet.workspace_repaired=no"
fi
if repair_worktree_metadata "${ESTNET_TEMPLATE_SOURCE_DIR}" "${ESTNET_TEMPLATE_DIR}" "estnet_template"; then
    append_summary "estnet_template.workspace_repaired=yes"
else
    append_summary "estnet_template.workspace_repaired=no"
fi

if [[ "$(git -C "${ESTNET_DIR}" rev-parse HEAD)" != "${ESTNET_COMMIT}" ]]; then
    stage_mark_failure "Workspace estnet at ${ESTNET_DIR} is not pinned to ${ESTNET_COMMIT}."
fi
if [[ "$(git -C "${ESTNET_TEMPLATE_DIR}" rev-parse HEAD)" != "${ESTNET_TEMPLATE_COMMIT}" ]]; then
    stage_mark_failure "Workspace estnet-template at ${ESTNET_TEMPLATE_DIR} is not pinned to ${ESTNET_TEMPLATE_COMMIT}."
fi

if [[ ! -f "${ESTNET_DIR}/INSTALL.md" ]] || [[ ! -d "${ESTNET_DIR}/src" ]]; then
    stage_mark_failure "Workspace ${ESTNET_DIR} does not look like the estnet project root."
fi
if [[ ! -f "${ESTNET_TEMPLATE_DIR}/README.md" ]] || [[ ! -d "${ESTNET_TEMPLATE_DIR}/simulations" ]]; then
    stage_mark_failure "Workspace ${ESTNET_TEMPLATE_DIR} does not look like the estnet-template project root."
fi

if [[ -n "$(git -C "${ESTNET_DIR}" status --short 2>/dev/null)" ]]; then
    append_summary "estnet.workspace_dirty=yes"
else
    append_summary "estnet.workspace_dirty=no"
fi
if [[ -n "$(git -C "${ESTNET_TEMPLATE_DIR}" status --short 2>/dev/null)" ]]; then
    append_summary "estnet_template.workspace_dirty=yes"
else
    append_summary "estnet_template.workspace_dirty=no"
fi

append_summary "estnet.workspace_head=$(git -C "${ESTNET_DIR}" rev-parse HEAD)"
append_summary "estnet_template.workspace_head=$(git -C "${ESTNET_TEMPLATE_DIR}" rev-parse HEAD)"

set_checkpoint "patch" "ensuring estnet-template runtime config patches are applied"
ensure_estnet_template_time_reference "${ESTNET_TEMPLATE_DIR}"
append_summary "patch.estnet_template_09_time_ref.status=applied_or_present"

if grep -q "openscenegraph-plugin-osgearth" "${ESTNET_DIR}/INSTALL.md"; then
    append_summary "estnet.install_mentions_obsolete_plugin=yes"
else
    append_summary "estnet.install_mentions_obsolete_plugin=no"
fi

stage_mark_success "estnet and estnet-template worktrees are prepared at pinned refs under ${WORKSPACE_ROOT}."
