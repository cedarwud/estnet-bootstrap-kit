#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "80" "smoke_test"
trap 'handle_unexpected_error $? ${LINENO} "${BASH_COMMAND}"' ERR

if stage_should_skip; then
    exit 0
fi

stage_begin_work

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

need_stage_success "70" "Stage 70 (activation script)"

ACTIVATE_ENV_FILE="${WORKSPACE_ROOT}/activate_env.sh"
FLOW_LOG="${LOG_DIR}/80_smoke_test.original_flow.${RUN_TS}.log"
ACTIVATE_LOG="${LOG_DIR}/80_smoke_test.activate_env.${RUN_TS}.log"

append_summary "runtime_policy=mark GUI checks skipped when blocked by WSL limitations"
append_summary "activation_script=${ACTIVATE_ENV_FILE}"

for required_path in \
    "${OMNETPP_DIR}/setenv" \
    "${OMNETPP_DIR}/bin/omnetpp" \
    "${OMNETPP_DIR}/bin/opp_run" \
    "${OMNETPP_DIR}/lib/liboppqtenv-osg.so" \
    "${INET_DIR}/setenv" \
    "${INET_DIR}/bin/inet" \
    "${INET_DIR}/src/libINET.so" \
    "${INET_DIR}/src/libINET_dbg.so" \
    "${OPENSCENEGRAPH_PREFIX}/lib/libosg.so" \
    "${OSGEARTH_27A_PREFIX}/lib64/libosgEarth.so" \
    "${OSGEARTH_27A_PREFIX}/data/moon_1024x512.jpg" \
    "${ESTNET_DIR}/INSTALL.md" \
    "${ESTNET_TEMPLATE_DIR}/README.md" \
    "${ACTIVATE_ENV_FILE}"; do
    if [[ ! -e "${required_path}" ]]; then
        stage_mark_failure "Required artifact is missing: ${required_path}"
    fi
    append_summary "artifact.present=${required_path}"
done

set_checkpoint "original_flow" "verifying requested manual activation flow"
if ! bash -lc 'cd "'"${OMNETPP_DIR}"'" && . ./setenv -f >/dev/null && cd "'"${INET_DIR}"'" && . ./setenv -f >/dev/null && command -v omnetpp && command -v inet && inet --release --printcmd' | tee "${FLOW_LOG}"; then
    stage_mark_failure "Original OMNeT++ -> INET activation flow failed. Inspect ${FLOW_LOG}."
fi

append_summary "original_flow_log=${FLOW_LOG}"

set_checkpoint "unified_flow" "verifying generated activation script"
if ! bash -lc 'source "'"${ACTIVATE_ENV_FILE}"'" && test "${OMNETPP_ROOT}" = "'"${OMNETPP_DIR}"'" && test "${INET_ROOT}" = "'"${INET_DIR}"'" && test "${ESTNET_ROOT}" = "'"${ESTNET_DIR}"'" && case ":${OSG_FILE_PATH:-}:" in *:"'"${OSGEARTH_27A_PREFIX}"'/data":*) true ;; *) false ;; esac && command -v omnetpp && command -v inet && inet --debug --printcmd' | tee "${ACTIVATE_LOG}"; then
    stage_mark_failure "Unified activation script smoke test failed. Inspect ${ACTIVATE_LOG}."
fi

append_summary "activation_flow_log=${ACTIVATE_LOG}"

set_checkpoint "gui_policy" "classifying GUI validation on WSL baseline"
if grep -qi microsoft /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    append_summary "gui_test=skipped"
    append_summary "gui_skip_reason=WSL build/debug baseline; GUI runtime validation is deferred to VMware or another stable Linux GUI environment."
    append_summary "display_env=${DISPLAY:-unset}"
    append_summary "wayland_env=${WAYLAND_DISPLAY:-unset}"
else
    append_summary "gui_test=not_run"
    append_summary "gui_skip_reason=Current workflow only validates activation and binary/library presence."
fi

stage_mark_success "Smoke test passed for original flow and unified activation script; GUI runtime launch remains intentionally skipped on WSL baseline."
