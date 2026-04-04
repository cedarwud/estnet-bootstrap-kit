#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/versions.env"
if [[ -f "${PROJECT_ROOT}/.env.local" ]]; then
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/.env.local"
fi
source "${PROJECT_ROOT}/paths.env"

FORCE_REBUILD="${FORCE_REBUILD:-0}"
_STAGE_REDIRECTED="${_STAGE_REDIRECTED:-0}"
PREVIOUS_STAGE_STATUS=""
PREVIOUS_STAGE_MESSAGE=""

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log() {
    local level="$1"
    shift
    printf "[%s] [%s] %s\n" "$(timestamp)" "${level}" "$*"
}

write_state() {
    local status="$1"
    local message="$2"
    printf "status=%s\nupdated_at=%s\nlog=%s\nmessage=%s\n" \
        "${status}" "$(timestamp)" "${STAGE_LOG:-}" "${message}" > "${STATE_FILE}"
}

append_summary() {
    printf "%s\n" "$*" >> "${SUMMARY_FILE}"
}

set_checkpoint() {
    local checkpoint="$1"
    local note="$2"
    printf "stage=%s\ncheckpoint=%s\nupdated_at=%s\nnote=%s\n" \
        "${STAGE_ID}" "${checkpoint}" "$(timestamp)" "${note}" > "${CHECKPOINT_FILE}"
}

init_stage() {
    local stage_id="$1"
    local stage_name="$2"

    export STAGE_ID="${stage_id}"
    export STAGE_NAME="${stage_name}"
    export RUN_TS
    RUN_TS="$(date "+%Y%m%d_%H%M%S")"

    mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BUILD_DIR}" "${SOURCES_DIR}" "${THIRD_PARTY_INSTALL_DIR}"

    export STAGE_LOG="${LOG_DIR}/${STAGE_ID}_${STAGE_NAME}_${RUN_TS}.log"
    export LATEST_LOG_LINK="${LOG_DIR}/${STAGE_ID}_${STAGE_NAME}.latest.log"
    export STATE_FILE="${STATE_DIR}/${STAGE_ID}.state"
    export SUMMARY_FILE="${STATE_DIR}/${STAGE_ID}.summary"
    export CHECKPOINT_FILE="${STATE_DIR}/${STAGE_ID}.checkpoint"

    if [[ "${_STAGE_REDIRECTED}" != "1" ]]; then
        exec > >(tee -a "${STAGE_LOG}") 2>&1
        _STAGE_REDIRECTED="1"
    fi

    ln -sfn "$(basename "${STAGE_LOG}")" "${LATEST_LOG_LINK}"

    log INFO "Stage ${STAGE_ID} (${STAGE_NAME}) started"
    log INFO "Project root: ${PROJECT_ROOT}"
    log INFO "Log file: ${STAGE_LOG}"

    if [[ -f "${STATE_FILE}" ]]; then
        PREVIOUS_STAGE_STATUS="$(sed -n 's/^status=//p' "${STATE_FILE}" | head -n1)"
        PREVIOUS_STAGE_MESSAGE="$(sed -n 's/^message=//p' "${STATE_FILE}" | head -n1)"
    fi
}

stage_should_skip() {
    if [[ "${PREVIOUS_STAGE_STATUS}" == "success" ]] && [[ "${FORCE_REBUILD}" != "1" ]]; then
        log INFO "Existing success state detected, skipping stage ${STAGE_ID}. Use FORCE_REBUILD=1 or --force to rerun."
        log INFO "Previous success message: ${PREVIOUS_STAGE_MESSAGE:-n/a}"
        return 0
    fi
    return 1
}

stage_begin_work() {
    : > "${SUMMARY_FILE}"
    write_state "running" "Stage started"
    set_checkpoint "start" "initialized"
}

stage_mark_success() {
    local message="$1"
    write_state "success" "${message}"
    set_checkpoint "done" "${message}"
    append_summary "result=success"
    append_summary "message=${message}"
    log INFO "Stage ${STAGE_ID} succeeded: ${message}"
}

stage_mark_failure() {
    local message="$1"
    write_state "failed" "${message}"
    set_checkpoint "failed" "${message}"
    append_summary "result=failed"
    append_summary "message=${message}"
    log ERROR "Stage ${STAGE_ID} failed: ${message}"
    exit 1
}

stage_mark_pending() {
    local message="$1"
    write_state "pending" "${message}"
    set_checkpoint "pending" "${message}"
    append_summary "result=pending"
    append_summary "message=${message}"
    log WARN "Stage ${STAGE_ID} pending: ${message}"
    exit 2
}

handle_unexpected_error() {
    local exit_code="$1"
    local line_no="$2"
    local command="$3"
    set +e
    write_state "failed" "Unhandled error at line ${line_no}: ${command}"
    set_checkpoint "failed" "Unhandled error at line ${line_no}"
    append_summary "result=failed"
    append_summary "message=Unhandled error at line ${line_no}: ${command}"
    log ERROR "Unhandled error at line ${line_no}: ${command} (exit ${exit_code})"
    exit "${exit_code}"
}

command_version_line() {
    local cmd="$1"
    local output=""
    case "${cmd}" in
        java|javac)
            output="$("${cmd}" -version 2>&1 || true)"
            ;;
        *)
            output="$("${cmd}" --version 2>&1 || true)"
            ;;
    esac

    printf "%s\n" "${output%%$'\n'*}"
}

is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]
}

linux_distro_id() {
    if [[ -r /etc/os-release ]]; then
        awk -F= '/^ID=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release
    fi
}

linux_os_release_value() {
    local key="$1"
    if [[ -r /etc/os-release ]]; then
        awk -F= -v key="${key}" '
            $1 == key {
                gsub(/"/, "", $2)
                print $2
                exit
            }
        ' /etc/os-release
    fi
}

linux_distro_version_id() {
    linux_os_release_value "VERSION_ID"
}

linux_distro_codename() {
    local codename
    codename="$(linux_os_release_value "VERSION_CODENAME")"
    if [[ -n "${codename}" ]]; then
        printf "%s\n" "${codename}"
        return 0
    fi
    linux_os_release_value "UBUNTU_CODENAME"
}

package_exists_in_apt_cache() {
    local pkg="$1"
    command -v apt-cache >/dev/null 2>&1 && apt-cache show "${pkg}" >/dev/null 2>&1
}

first_available_apt_package() {
    local pkg=""
    for pkg in "$@"; do
        if package_exists_in_apt_cache "${pkg}"; then
            printf "%s\n" "${pkg}"
            return 0
        fi
    done
    return 1
}

select_webkit_runtime_package() {
    local distro version
    distro="$(linux_distro_id || true)"
    version="$(linux_distro_version_id || true)"

    if [[ "${distro}" == "ubuntu" ]]; then
        case "${version}" in
            24.*|25.*|26.*)
                first_available_apt_package "libwebkit2gtk-4.1-0" "libwebkit2gtk-4.0-37" && return 0
                ;;
            20.*|22.*)
                first_available_apt_package "libwebkit2gtk-4.0-37" "libwebkit2gtk-4.1-0" && return 0
                ;;
        esac
    fi

    first_available_apt_package "libwebkit2gtk-4.1-0" "libwebkit2gtk-4.0-37"
}

select_freetype_dev_package() {
    local distro version
    distro="$(linux_distro_id || true)"
    version="$(linux_distro_version_id || true)"

    if [[ "${distro}" == "ubuntu" ]]; then
        case "${version}" in
            24.*|25.*|26.*)
                first_available_apt_package "libfreetype-dev" "libfreetype6-dev" && return 0
                ;;
            20.*|22.*)
                first_available_apt_package "libfreetype6-dev" "libfreetype-dev" && return 0
                ;;
        esac
    fi

    first_available_apt_package "libfreetype6-dev" "libfreetype-dev"
}

detect_virtualization() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt 2>/dev/null || true
        return 0
    fi

    if [[ -r /sys/class/dmi/id/product_name ]]; then
        cat /sys/class/dmi/id/product_name
        return 0
    fi

    printf "unknown\n"
}

detect_runtime_environment() {
    local distro virt
    distro="$(linux_distro_id)"
    virt="$(detect_virtualization)"

    if is_wsl; then
        printf "wsl\n"
    elif [[ "${virt}" == "vmware" ]]; then
        printf "vmware\n"
    elif [[ "${virt}" == "oracle" ]] || [[ "${virt}" == "virtualbox" ]]; then
        printf "virtualbox\n"
    elif [[ -n "${virt}" && "${virt}" != "none" && "${virt}" != "unknown" ]]; then
        printf "virtualized\n"
    elif [[ -n "${distro}" ]]; then
        printf "native-linux\n"
    else
        printf "unknown\n"
    fi
}

default_gl_mode_for_environment() {
    case "$(detect_runtime_environment)" in
        wsl)
            printf "software\n"
            ;;
        *)
            printf "native\n"
            ;;
    esac
}

relative_path() {
    local target="$1"
    local base="$2"
    python3 - "$target" "$base" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
}

repair_worktree_metadata() {
    local source_dir="$1"
    local target_dir="$2"
    local label="$3"
    local target_git_file="${target_dir}/.git"
    local worktree_name expected_gitdir target_parent metadata_parent rel_to_metadata rel_to_target

    if git -C "${target_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi

    if [[ ! -f "${target_git_file}" ]]; then
        log WARN "Skipping ${label} worktree repair because ${target_git_file} is missing or not a file."
        return 1
    fi

    worktree_name="$(basename "${target_dir}")"
    expected_gitdir="${source_dir}/.git/worktrees/${worktree_name}"
    if [[ ! -d "${expected_gitdir}" ]]; then
        log WARN "Skipping ${label} worktree repair because expected metadata dir is missing: ${expected_gitdir}"
        return 1
    fi

    target_parent="$(dirname "${target_git_file}")"
    metadata_parent="${expected_gitdir}"
    rel_to_metadata="$(relative_path "${expected_gitdir}" "${target_parent}")"
    rel_to_target="$(relative_path "${target_git_file}" "${metadata_parent}")"

    printf "gitdir: %s\n" "${rel_to_metadata}" > "${target_git_file}"
    printf "%s\n" "${rel_to_target}" > "${expected_gitdir}/gitdir"

    if git -C "${target_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        log INFO "Repaired moved worktree metadata for ${label}: ${target_dir}"
        return 0
    fi

    log WARN "Attempted repair for ${label} worktree metadata, but git still cannot resolve ${target_dir}"
    return 1
}

ensure_git_patch_applied() {
    local repo_dir="$1"
    local patch_file="$2"
    local label="$3"

    if ! git -C "${repo_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        stage_mark_failure "Patch target is not a git repository: ${repo_dir}"
    fi

    if [[ ! -f "${patch_file}" ]]; then
        stage_mark_failure "Required patch file is missing: ${patch_file}"
    fi

    append_summary "patch.${label}.file=${patch_file}"

    if git -C "${repo_dir}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
        append_summary "patch.${label}.status=already_applied"
        log INFO "Patch '${label}' already applied in ${repo_dir}"
        return 0
    fi

    if git -C "${repo_dir}" apply --check "${patch_file}" >/dev/null 2>&1; then
        git -C "${repo_dir}" apply "${patch_file}"
        append_summary "patch.${label}.status=applied"
        log INFO "Applied patch '${label}' in ${repo_dir}"
        return 0
    fi

    append_summary "patch.${label}.status=failed_check"
    stage_mark_failure "Patch '${label}' could not be applied cleanly in ${repo_dir}. Inspect local source changes and ${patch_file}."
}
