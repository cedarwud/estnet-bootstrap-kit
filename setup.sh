#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT
source "${PROJECT_ROOT}/scripts/common.sh"

usage() {
    cat <<'EOF'
Usage: ./setup.sh [ready|baseline|full|ide] [--force] [--skip-apt] [--print-apt-command]

Default:
  ready     Preferred one-time setup path for a new environment.

Modes:
  ready     Build the preferred baseline flow and OMNeT++ IDE payload.
  baseline  Build only the baseline flow, without IDE packaging.
  full      Build baseline + osgEarth Method B + OMNeT++ IDE payload.
  ide       Rebuild only the OMNeT++ IDE payload.

Options:
  --force             Force rerun each stage even if state says success.
  --skip-apt          Skip apt prerequisite installation in setup.sh.
  --print-apt-command Print the Ubuntu/WSL prerequisite install command and exit.
EOF
}

MODE="ready"
SKIP_APT=0
PRINT_APT_COMMAND=0

prerequisite_packages() {
    cat <<'EOF'
build-essential
cmake
clang
pkg-config
python3
python-is-python3
default-jre
default-jdk
bison
flex
maven
swig
qtbase5-dev
qtchooser
qt5-qmake
qtbase5-dev-tools
libqt5opengl5-dev
EOF
    select_webkit_runtime_package || true
    cat <<'EOF'
xcursor-themes
libgl1-mesa-dev
libglu1-mesa-dev
freeglut3-dev
libxrandr-dev
libxinerama-dev
libxcursor-dev
libxi-dev
libxmu-dev
mesa-utils
libjpeg-dev
libpng-dev
libtiff-dev
EOF
    select_freetype_dev_package || true
    cat <<'EOF'
zlib1g-dev
libfontconfig1-dev
libcurl4-openssl-dev
libgdal-dev
libgeos-dev
libsqlite3-dev
EOF
}

print_apt_install_command() {
    local pkg=""
    printf "sudo apt-get update\n"
    printf "sudo apt-get install -y"
    while IFS= read -r pkg; do
        [[ -n "${pkg}" ]] || continue
        printf ' \
  %s' "${pkg}"
    done < <(prerequisite_packages)
    printf "\n"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        ready|baseline|full|ide)
            MODE="$1"
            shift
            ;;
        --skip-apt)
            SKIP_APT=1
            shift
            ;;
        --print-apt-command)
            PRINT_APT_COMMAND=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --force)
            break
            ;;
        *)
            printf "Unknown argument: %s\n\n" "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "${PRINT_APT_COMMAND}" == "1" ]]; then
    print_apt_install_command
    exit 0
fi

install_prerequisites() {
    if [[ "${SKIP_APT}" == "1" ]]; then
        printf "[setup] skip apt prerequisite installation (--skip-apt)\n"
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        printf "[setup] apt-get not found; skipping prerequisite installation\n"
        return 0
    fi

    local -a packages=()
    local pkg=""
    while IFS= read -r pkg; do
        [[ -n "${pkg}" ]] || continue
        packages+=("${pkg}")
    done < <(prerequisite_packages)

    if ! printf '%s\n' "${packages[@]}" | grep -q '^libwebkit2gtk-'; then
        printf "[setup] warning: no supported WebKitGTK runtime package detected in apt cache; IDE embedded browser features may be unavailable\n" >&2
    fi
    if ! printf '%s\n' "${packages[@]}" | grep -Eq '^libfreetype(6)?-dev$'; then
        printf "[setup] warning: no supported FreeType development package detected in apt cache; OpenSceneGraph build may fail later\n" >&2
    fi

    printf "[setup] installing Ubuntu prerequisites via apt\n"
    if sudo -n true >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y "${packages[@]}"
        return 0
    fi

    if [[ -t 0 && -t 1 ]]; then
        sudo apt-get update
        sudo apt-get install -y "${packages[@]}"
        return 0
    fi

    printf "[setup] sudo privileges are required to install Ubuntu prerequisites.\n" >&2
    printf "[setup] In non-interactive sessions, install them manually with:\n\n" >&2
    print_apt_install_command >&2
    printf "\n[setup] After that, continue with:\n" >&2
    printf "  ./setup.sh --skip-apt"
    if [[ "${MODE}" != "ready" ]]; then
        printf " %s" "${MODE}"
    fi
    printf "\n" >&2
    exit 2
}

cd "${PROJECT_ROOT}"
printf "[setup] environment=%s distro=%s version=%s codename=%s virt=%s\n" \
    "$(detect_runtime_environment)" \
    "$(linux_distro_id || true)" \
    "$(linux_distro_version_id || true)" \
    "$(linux_distro_codename || true)" \
    "$(detect_virtualization || true)"
install_prerequisites
exec "${PROJECT_ROOT}/tools/run_all.sh" "${MODE}" "$@"
