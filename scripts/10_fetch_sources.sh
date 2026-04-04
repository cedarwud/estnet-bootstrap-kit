#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "10" "fetch_sources"
trap 'handle_unexpected_error $? ${LINENO} "${BASH_COMMAND}"' ERR

if stage_should_skip; then
    exit 0
fi

stage_begin_work

need_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        append_summary "missing_tool=${cmd}"
        stage_mark_failure "Required command '${cmd}' is missing. Install package '${pkg}' and rerun Stage 10."
    fi
}

verify_clean_git_repo() {
    local label="$1"
    local dir="$2"
    local url="$3"

    if [[ ! -d "${dir}/.git" ]]; then
        stage_mark_failure "${label} path exists but is not a git repository: ${dir}"
    fi

    local origin_url
    origin_url="$(git -C "${dir}" remote get-url origin 2>/dev/null || true)"
    if [[ "${origin_url}" != "${url}" ]]; then
        append_summary "repo.${label}.origin=${origin_url}"
        stage_mark_failure "${label} repository origin mismatch at ${dir}; expected ${url}, got ${origin_url:-<none>}."
    fi

    if [[ -n "$(git -C "${dir}" status --porcelain)" ]]; then
        stage_mark_failure "${label} repository has local modifications at ${dir}; refusing to overwrite."
    fi
}

sync_repo_to_ref() {
    local label="$1"
    local url="$2"
    local dir="$3"
    local ref="$4"
    local expected_commit="$5"
    local use_submodules="${6:-no}"

    set_checkpoint "fetch_${label}" "syncing ${label} to ${ref}"

    if [[ -e "${dir}" ]] && [[ ! -d "${dir}" ]]; then
        stage_mark_failure "${label} target path exists but is not a directory: ${dir}"
    fi

    if [[ ! -d "${dir}" ]]; then
        log INFO "Cloning ${label}: ${url} -> ${dir} @ ${ref}"
        git clone --branch "${ref}" --single-branch "${url}" "${dir}"
    else
        verify_clean_git_repo "${label}" "${dir}" "${url}"
        local current_commit
        current_commit="$(git -C "${dir}" rev-parse HEAD)"
        if [[ "${current_commit}" != "${expected_commit}" ]]; then
            log INFO "Updating ${label} at ${dir} to ${ref}"
            git -C "${dir}" fetch --tags origin
        else
            log INFO "Reusing ${label} at pinned commit ${expected_commit}"
        fi
    fi

    verify_clean_git_repo "${label}" "${dir}" "${url}"

    git -C "${dir}" checkout --detach "${ref}"

    if [[ "${use_submodules}" == "yes" ]] && [[ -f "${dir}/.gitmodules" ]]; then
        log INFO "Updating ${label} submodules"
        git -C "${dir}" submodule sync --recursive
        git -C "${dir}" submodule update --init --recursive
    fi

    local resolved_commit
    resolved_commit="$(git -C "${dir}" rev-parse HEAD)"
    if [[ "${resolved_commit}" != "${expected_commit}" ]]; then
        append_summary "repo.${label}.resolved_commit=${resolved_commit}"
        append_summary "repo.${label}.expected_commit=${expected_commit}"
        stage_mark_failure "${label} resolved to unexpected commit ${resolved_commit}; expected ${expected_commit}."
    fi

    append_summary "repo.${label}.url=${url}"
    append_summary "repo.${label}.ref=${ref}"
    append_summary "repo.${label}.commit=${resolved_commit}"
    append_summary "repo.${label}.dir=${dir}"
}

need_command "git" "git"

mkdir -p "${SOURCES_DIR}"

append_summary "planned_sources=OMNeT++, INET, OpenSceneGraph, osgEarth, estnet, estnet-template"

sync_repo_to_ref "omnetpp" "${OMNETPP_REPO_URL}" "${OMNETPP_DIR}" "${OMNETPP_REF}" "${OMNETPP_COMMIT}" "no"
sync_repo_to_ref "inet" "${INET_REPO_URL}" "${INET_SOURCE_DIR}" "${INET_REF}" "${INET_COMMIT}" "no"
sync_repo_to_ref "openscenegraph" "${OPENSCENEGRAPH_REPO_URL}" "${OPENSCENEGRAPH_SOURCE_DIR}" "${OPENSCENEGRAPH_REF}" "${OPENSCENEGRAPH_COMMIT}" "no"
sync_repo_to_ref "osgearth" "${OSGEARTH_REPO_URL}" "${OSGEARTH_SOURCE_DIR}" "${OSGEARTH_REF_METHOD_A}" "${OSGEARTH_COMMIT}" "yes"
sync_repo_to_ref "estnet" "${ESTNET_REPO_URL}" "${ESTNET_SOURCE_DIR}" "${ESTNET_REF}" "${ESTNET_COMMIT}" "no"
sync_repo_to_ref "estnet_template" "${ESTNET_TEMPLATE_REPO_URL}" "${ESTNET_TEMPLATE_SOURCE_DIR}" "${ESTNET_TEMPLATE_REF}" "${ESTNET_TEMPLATE_COMMIT}" "no"

append_summary "pinning_status=complete"
stage_mark_success "Fetched and pinned OMNeT++, INET, OpenSceneGraph, osgEarth 2.7, estnet, and estnet-template sources."
