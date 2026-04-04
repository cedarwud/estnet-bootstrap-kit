#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "50" "build_inet"
trap 'handle_unexpected_error $? ${LINENO} "${BASH_COMMAND}"' ERR

if stage_should_skip; then
    exit 0
fi

stage_begin_work

need_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        stage_mark_failure "Required command '${cmd}' is missing. Install package '${pkg}' and rerun Stage 50."
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

sanitize_inet_ide_metadata() {
    local inet_dir="$1"
    local cproject_file="${inet_dir}/.cproject"

    if [[ ! -f "${cproject_file}" ]]; then
        stage_mark_failure "Expected INET IDE metadata file is missing: ${cproject_file}"
    fi

    python3 - "${cproject_file}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
original = path.read_text(encoding="utf-8")
updated = original.replace('value="../../src"', 'value="&quot;${workspace_loc:/inet/src}&quot;"')

if updated != original:
    path.write_text(updated, encoding="utf-8")
    print("patched")
else:
    print("unchanged")
PY
}

find_single_workspace_match() {
    local pattern="$1"
    mapfile -t _matches < <(find "${WORKSPACE_ROOT}" -mindepth 1 -maxdepth 1 -type d -name "${pattern}" | sort)
    if [[ "${#_matches[@]}" -gt 1 ]]; then
        printf "MULTIPLE\n"
        printf "%s\n" "${_matches[@]}"
        return 0
    fi
    if [[ "${#_matches[@]}" -eq 1 ]]; then
        printf "%s\n" "${_matches[0]}"
    fi
}

need_command "git" "git"
need_command "grep" "grep"
need_command "find" "findutils"
need_command "make" "make"
need_command "python3" "python3"

need_stage_success "40" "Stage 40 (OMNeT++ build)"

if [[ ! -d "${OMNETPP_DIR}" ]] || [[ ! -x "${OMNETPP_DIR}/bin/opp_run" ]]; then
    stage_mark_failure "OMNeT++ build artifacts are missing under ${OMNETPP_DIR}. Re-run Stage 40."
fi

if [[ ! -d "${INET_SOURCE_DIR}/.git" ]]; then
    stage_mark_failure "Pinned INET source mirror is missing at ${INET_SOURCE_DIR}. Run Stage 10 first."
fi

if [[ "$(git -C "${INET_SOURCE_DIR}" rev-parse HEAD)" != "${INET_COMMIT}" ]]; then
    stage_mark_failure "INET source mirror at ${INET_SOURCE_DIR} is not pinned to ${INET_COMMIT}. Re-run Stage 10."
fi

append_summary "inet_source_dir=${INET_SOURCE_DIR}"
append_summary "inet_ref=${INET_REF}"
append_summary "inet_commit=${INET_COMMIT}"
append_summary "inet_workspace_dir=${INET_DIR}"
append_summary "compat_patch=${INET_420_OSG_LINK_PATCH}"

PYTHON_SHIM_DIR="${THIRD_PARTY_INSTALL_DIR}/toolchain-shims/bin"
if command -v python >/dev/null 2>&1; then
    append_summary "python_command=$(command -v python)"
else
    mkdir -p "${PYTHON_SHIM_DIR}"
    ln -sfn "$(command -v python3)" "${PYTHON_SHIM_DIR}/python"
    export PATH="${PYTHON_SHIM_DIR}:${PATH}"
    append_summary "python_command=${PYTHON_SHIM_DIR}/python"
    append_summary "python_shim_target=$(command -v python3)"
fi

set_checkpoint "workspace" "preparing workspace inet directory"

if [[ -d "${INET_DIR}" ]]; then
    append_summary "workspace_origin=existing_inet_dir"
    log INFO "Using existing INET workspace directory at ${INET_DIR}"
else
    existing_inet4="$(find_single_workspace_match 'inet4*')"
    if [[ -n "${existing_inet4}" ]]; then
        if [[ "${existing_inet4}" == "MULTIPLE" ]]; then
            stage_mark_failure "Multiple root-level inet4* directories exist under ${WORKSPACE_ROOT}. Resolve them before rerunning Stage 50."
        fi
        mv "${existing_inet4}" "${INET_DIR}"
        append_summary "workspace_origin=renamed_from_existing_root_dir"
        append_summary "renamed_from=${existing_inet4}"
        log INFO "Renamed ${existing_inet4} to ${INET_DIR}"
    else
        git -C "${INET_SOURCE_DIR}" worktree add --detach "${INET_DIR}" "${INET_COMMIT}"
        append_summary "workspace_origin=git_worktree_from_pinned_source"
        append_summary "worktree_source=${INET_SOURCE_DIR}"
        log INFO "Created INET workspace worktree at ${INET_DIR}"
    fi
fi

if [[ ! -f "${INET_DIR}/setenv" ]] || [[ ! -f "${INET_DIR}/Makefile" ]]; then
    stage_mark_failure "Directory ${INET_DIR} does not look like an INET root after preparation."
fi

if repair_worktree_metadata "${INET_SOURCE_DIR}" "${INET_DIR}" "inet"; then
    append_summary "inet_workspace_repaired=yes"
else
    append_summary "inet_workspace_repaired=no"
fi

if ! git -C "${INET_DIR}" rev-parse HEAD >/dev/null 2>&1; then
    stage_mark_failure "INET workspace at ${INET_DIR} is not a git working tree, so version pinning cannot be verified."
fi

if [[ "$(git -C "${INET_DIR}" rev-parse HEAD)" != "${INET_COMMIT}" ]]; then
    stage_mark_failure "INET workspace at ${INET_DIR} is not pinned to ${INET_COMMIT}."
fi

if [[ -n "$(git -C "${INET_DIR}" status --short 2>/dev/null)" ]]; then
    append_summary "inet_workspace_dirty=yes"
else
    append_summary "inet_workspace_dirty=no"
fi

append_summary "inet_workspace_head=$(git -C "${INET_DIR}" rev-parse HEAD)"

set_checkpoint "ide_metadata" "sanitizing INET Eclipse project metadata for portable workspace imports"
INET_IDE_METADATA_STATUS="$(sanitize_inet_ide_metadata "${INET_DIR}")"
append_summary "inet_ide_metadata_status=${INET_IDE_METADATA_STATUS}"

set_checkpoint "patch" "ensuring INET local OSG link patch is applied"
ensure_git_patch_applied "${INET_DIR}" "${INET_420_OSG_LINK_PATCH}" "inet_420_local_osg_link"

set_checkpoint "env_check" "validating OMNeT++ and INET setenv chaining"
if ! (
    cd "${OMNETPP_DIR}"
    . ./setenv -f >/dev/null
    cd "${INET_DIR}"
    . ./setenv -f >/dev/null
    command -v opp_makemake >/dev/null
    command -v opp_featuretool >/dev/null
    command -v inet >/dev/null
    printf "INET_ROOT=%s\n" "${INET_ROOT}"
    printf "INET_NED_PATH=%s\n" "${INET_NED_PATH}"
) | tee "${LOG_DIR}/50_build_inet.env.${RUN_TS}.log"; then
    stage_mark_failure "OMNeT++/INET setenv chaining validation failed. Inspect ${LOG_DIR}/50_build_inet.env.${RUN_TS}.log."
fi

append_summary "env_validation_log=${LOG_DIR}/50_build_inet.env.${RUN_TS}.log"

set_checkpoint "feature_state" "initializing INET feature state and generated headers"
if [[ ! -f "${INET_DIR}/.oppfeaturestate" ]]; then
    if ! (
        cd "${OMNETPP_DIR}"
        . ./setenv -f >/dev/null
        cd "${INET_DIR}"
        . ./setenv -f >/dev/null
        opp_featuretool reset
    ); then
        stage_mark_failure "Failed to initialize INET feature state with opp_featuretool reset."
    fi
    append_summary "oppfeaturestate.created=yes"
else
    append_summary "oppfeaturestate.created=no"
fi

if ! (
    cd "${OMNETPP_DIR}"
    . ./setenv -f >/dev/null
    cd "${INET_DIR}"
    . ./setenv -f >/dev/null
    opp_featuretool validate
    opp_featuretool defines > src/inet/features.h
); then
    stage_mark_failure "Failed to validate INET feature state or regenerate src/inet/features.h."
fi

append_summary "artifact.feature_state=${INET_DIR}/.oppfeaturestate"
append_summary "artifact.features_header=${INET_DIR}/src/inet/features.h"

set_checkpoint "makefiles" "generating INET makefiles"
if ! (
    cd "${OMNETPP_DIR}"
    . ./setenv -f >/dev/null
    cd "${INET_DIR}"
    . ./setenv -f >/dev/null
    make makefiles
); then
    stage_mark_failure "INET makefile generation failed. Inspect ${STAGE_LOG}."
fi

if [[ ! -f "${INET_DIR}/src/Makefile" ]]; then
    stage_mark_failure "INET makefile generation did not produce ${INET_DIR}/src/Makefile"
fi

append_summary "artifact.makefile=${INET_DIR}/src/Makefile"

set_checkpoint "build_release" "building INET release"
if ! (
    cd "${OMNETPP_DIR}"
    . ./setenv -f >/dev/null
    cd "${INET_DIR}"
    . ./setenv -f >/dev/null
    make -j"${BUILD_JOBS}"
); then
    stage_mark_failure "INET release build failed. Inspect ${STAGE_LOG}."
fi

set_checkpoint "build_debug" "building INET debug"
if ! (
    cd "${OMNETPP_DIR}"
    . ./setenv -f >/dev/null
    cd "${INET_DIR}"
    . ./setenv -f >/dev/null
    make MODE=debug -j"${BUILD_JOBS}"
); then
    stage_mark_failure "INET debug build failed. Inspect ${STAGE_LOG}."
fi

INET_RELEASE_LIB="$(find "${INET_DIR}/src" -maxdepth 2 -type f -name "libINET.so" | sort | head -n1)"
INET_DEBUG_LIB="$(find "${INET_DIR}/src" -maxdepth 2 -type f -name "libINET_dbg.so" | sort | head -n1)"

if [[ -z "${INET_RELEASE_LIB}" ]]; then
    stage_mark_failure "INET release build completed but libINET.so was not found under ${INET_DIR}/src"
fi
if [[ -z "${INET_DEBUG_LIB}" ]]; then
    stage_mark_failure "INET debug build completed but libINET_dbg.so was not found under ${INET_DIR}/src"
fi

append_summary "artifact.release_lib=${INET_RELEASE_LIB}"
append_summary "artifact.debug_lib=${INET_DEBUG_LIB}"
append_summary "artifact.bin_inet=${INET_DIR}/bin/inet"

set_checkpoint "validate_runner" "validating inet runner resolution"
INET_PRINTCMD_CAPTURE="${LOG_DIR}/50_build_inet.printcmd.${RUN_TS}.log"
if ! (
    cd "${OMNETPP_DIR}"
    . ./setenv -f >/dev/null
    cd "${INET_DIR}"
    . ./setenv -f >/dev/null
    inet --release --printcmd
) | tee "${INET_PRINTCMD_CAPTURE}"; then
    stage_mark_failure "INET runner validation command failed. Inspect ${INET_PRINTCMD_CAPTURE}."
fi

if ! grep -q "opp_run" "${INET_PRINTCMD_CAPTURE}"; then
    stage_mark_failure "INET runner validation did not resolve to opp_run. Inspect ${INET_PRINTCMD_CAPTURE}."
fi

append_summary "runner_validation_log=${INET_PRINTCMD_CAPTURE}"
stage_mark_success "INET ${INET_VERSION} prepared in ${INET_DIR}, makefiles generated, and release/debug builds succeeded."
