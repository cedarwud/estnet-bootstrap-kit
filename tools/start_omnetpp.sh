#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT
source "${PROJECT_ROOT}/scripts/common.sh"
GL_MODE="${OMNETPP_GL_MODE:-auto}"
ENV_KIND="$(detect_runtime_environment)"
GDK_MODE="${OMNETPP_GDK_BACKEND:-auto}"
QT_PLATFORM_MODE="${OMNETPP_QT_PLATFORM_MODE:-auto}"

is_wayland_session() {
    [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]
}

default_qt_platform_for_environment() {
    local distro
    distro="$(linux_distro_id || true)"

    if [[ "${ENV_KIND}" != "wsl" ]] && is_wayland_session; then
        case "${ENV_KIND}" in
            native-linux|vmware|virtualbox|virtualized)
                if [[ -n "${distro}" ]]; then
                    printf "xcb\n"
                    return 0
                fi
                ;;
        esac
    fi

    printf "\n"
}

cursor_theme_has_hand2() {
    local theme="${1:-}"
    local base="/usr/share/icons"
    [[ -n "${theme}" ]] || return 1
    [[ -e "${base}/${theme}/cursors/hand2" ]] || return 1
}

select_cursor_theme_with_hand2() {
    local current_theme=""
    current_theme="${XCURSOR_THEME:-}"

    if [[ -z "${current_theme}" ]] && command -v gsettings >/dev/null 2>&1; then
        current_theme="$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null | tr -d "'" || true)"
    fi

    if cursor_theme_has_hand2 "${current_theme}"; then
        return 0
    fi

    local fallback=""
    for fallback in whiteglass redglass handhelds; do
        if cursor_theme_has_hand2 "${fallback}"; then
            export XCURSOR_THEME="${fallback}"
            export XCURSOR_PATH="/usr/share/icons"
            printf "[run] cursor_theme_fallback=%s\n" "${fallback}"
            return 0
        fi
    done

    return 1
}

has_argument() {
    local needle="$1"
    shift
    local arg=""
    for arg in "$@"; do
        if [[ "${arg}" == "${needle}" ]]; then
            return 0
        fi
    done
    return 1
}

case "${1:-}" in
    --software-gl)
        GL_MODE="software"
        shift
        ;;
    --native-gl)
        GL_MODE="native"
        shift
        ;;
esac

if [[ ! -f "${PROJECT_ROOT}/activate_env.sh" ]]; then
    printf "Missing %s/activate_env.sh. Run ./setup.sh first in this project root.\n" "${PROJECT_ROOT}" >&2
    exit 1
fi

source "${PROJECT_ROOT}/activate_env.sh"

if [[ "${GL_MODE}" == "auto" ]]; then
    GL_MODE="$(default_gl_mode_for_environment)"
fi

if [[ "${GDK_MODE}" == "auto" ]]; then
    if [[ "${ENV_KIND}" == "wsl" ]]; then
        GDK_MODE="x11"
    else
        GDK_MODE=""
    fi
fi

if [[ "${QT_PLATFORM_MODE}" == "auto" ]] && [[ -z "${QT_QPA_PLATFORM:-}" ]]; then
    QT_PLATFORM_MODE="$(default_qt_platform_for_environment)"
fi

printf "[run] environment=%s distro=%s version=%s codename=%s virt=%s gl_mode=%s\n" \
    "${ENV_KIND}" \
    "$(linux_distro_id || true)" \
    "$(linux_distro_version_id || true)" \
    "$(linux_distro_codename || true)" \
    "$(detect_virtualization || true)" \
    "${GL_MODE}"

if [[ "${GL_MODE}" == "software" ]]; then
    # WSLg's D3D12-backed OpenGL translation is unstable with Qtenv+OSG/osgEarth.
    # Default to Mesa software rendering on WSL; keep native GL elsewhere.
    export LIBGL_ALWAYS_SOFTWARE=1
    export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
    export GALLIUM_DRIVER=llvmpipe
else
    unset LIBGL_ALWAYS_SOFTWARE
    unset MESA_LOADER_DRIVER_OVERRIDE
    unset GALLIUM_DRIVER
fi

select_cursor_theme_with_hand2 || true

if [[ -n "${GDK_MODE}" ]]; then
    export GDK_BACKEND="${GDK_MODE}"
    printf "[run] gdk_backend=%s\n" "${GDK_MODE}"
fi

if [[ -n "${QT_PLATFORM_MODE}" ]]; then
    export QT_QPA_PLATFORM="${QT_PLATFORM_MODE}"
    printf "[run] qt_qpa_platform=%s\n" "${QT_PLATFORM_MODE}"
fi

declare -a OMNETPP_ARGS=()
OMNETPP_ARGS=("$@")

if ! has_argument "-data" "${OMNETPP_ARGS[@]}"; then
    OMNETPP_ARGS+=("-data" "${PROJECT_ROOT}")
    printf "[run] workspace=%s\n" "${PROJECT_ROOT}"
fi

exec omnetpp "${OMNETPP_ARGS[@]}"
