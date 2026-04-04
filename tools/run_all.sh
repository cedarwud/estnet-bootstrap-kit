#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT

usage() {
    cat <<'EOF'
Usage: ./tools/run_all.sh [ready|full|baseline|ide] [--force]

Modes:
  ready     Preferred end-to-end path for a new environment; includes IDE packaging.
  full      Run the full validated flow, including Method B and IDE packaging.
  baseline  Run the preferred baseline flow, skipping Method B and IDE packaging.
  ide       Run only the IDE packaging stage.
EOF
}

MODE="ready"
FORCE=0

for arg in "$@"; do
    case "${arg}" in
        ready|full|baseline|ide)
            MODE="${arg}"
            ;;
        --force)
            FORCE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf "Unknown argument: %s\n\n" "${arg}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "${MODE}" in
    ready)
        STAGES=(00 10 20 30 40 50 60 70 80 90)
        ;;
    full)
        STAGES=(00 10 20 30 31 40 50 60 70 80 90)
        ;;
    baseline)
        STAGES=(00 10 20 30 40 50 60 70 80)
        ;;
    ide)
        STAGES=(90)
        ;;
esac

cd "${PROJECT_ROOT}"

printf "[run_all] project_root=%s mode=%s force=%s\n" "${PROJECT_ROOT}" "${MODE}" "${FORCE}"

for stage in "${STAGES[@]}"; do
    if [[ "${FORCE}" == "1" ]]; then
        "${PROJECT_ROOT}/tools/run_stage.sh" --force "${stage}"
    else
        "${PROJECT_ROOT}/tools/run_stage.sh" "${stage}"
    fi
done

printf "[run_all] completed mode=%s\n" "${MODE}"
