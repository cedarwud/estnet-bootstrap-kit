#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"

usage() {
    printf "Usage: %s [--force] <stage-id>\n" "$(basename "$0")"
    printf "       %s --list\n" "$(basename "$0")"
}

if [[ "${1:-}" == "--list" ]]; then
    find "${SCRIPTS_DIR}" -maxdepth 1 -type f -name "[0-9][0-9]_*.sh" | sort | xargs -n1 basename
    exit 0
fi

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
    shift
fi

STAGE_ID="${1:-}"
if [[ -z "${STAGE_ID}" ]]; then
    usage
    exit 1
fi

SCRIPT_PATH="$(find "${SCRIPTS_DIR}" -maxdepth 1 -type f -name "${STAGE_ID}_*.sh" | sort | head -n1)"
if [[ -z "${SCRIPT_PATH}" ]]; then
    printf "Stage not found: %s\n" "${STAGE_ID}" >&2
    exit 1
fi

printf "[run_stage] stage=%s script=%s force=%s\n" "${STAGE_ID}" "$(basename "${SCRIPT_PATH}")" "${FORCE}"

if [[ "${FORCE}" == "1" ]]; then
    export FORCE_REBUILD=1
fi

"${SCRIPT_PATH}"
