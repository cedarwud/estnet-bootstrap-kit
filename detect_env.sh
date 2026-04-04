#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT
source "${PROJECT_ROOT}/scripts/common.sh"

ENV_KIND="$(detect_runtime_environment)"
DISTRO_ID="$(linux_distro_id || true)"
DISTRO_VERSION_ID="$(linux_distro_version_id || true)"
DISTRO_CODENAME="$(linux_distro_codename || true)"
VIRT_KIND="$(detect_virtualization || true)"
DEFAULT_GL_MODE="$(default_gl_mode_for_environment)"

APT_MODE="auto"
if ! command -v apt-get >/dev/null 2>&1; then
    APT_MODE="unsupported"
fi

case "${ENV_KIND}" in
    wsl)
        RUN_DEFAULT="./run.sh"
        RUN_NOTE="WSL detected; run defaults to software GL automatically."
        ;;
    *)
        RUN_DEFAULT="./run.sh"
        RUN_NOTE="Non-WSL environment detected; run defaults to native GL."
        ;;
esac

cat <<EOF
project_root=${PROJECT_ROOT}
environment=${ENV_KIND}
distro=${DISTRO_ID:-unknown}
distro_version=${DISTRO_VERSION_ID:-unknown}
distro_codename=${DISTRO_CODENAME:-unknown}
virtualization=${VIRT_KIND:-unknown}
setup_apt_mode=${APT_MODE}
run_default_gl_mode=${DEFAULT_GL_MODE}
recommended_setup=./setup.sh
recommended_run=${RUN_DEFAULT}
note=${RUN_NOTE}
override_run_native=./run.sh --native-gl
override_run_software=./run.sh --software-gl
EOF
