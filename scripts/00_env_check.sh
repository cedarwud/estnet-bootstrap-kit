#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "00" "env_check"
trap 'handle_unexpected_error $? ${LINENO} "${BASH_COMMAND}"' ERR

if stage_should_skip; then
    exit 0
fi

stage_begin_work

declare -a MISSING_PACKAGES=()
declare -a RUNTIME_LIMITATIONS=()

add_missing_package() {
    local pkg="$1"
    local existing
    for existing in "${MISSING_PACKAGES[@]:-}"; do
        if [[ "${existing}" == "${pkg}" ]]; then
            return 0
        fi
    done
    MISSING_PACKAGES+=("${pkg}")
}

add_runtime_limitation() {
    local note="$1"
    local existing
    for existing in "${RUNTIME_LIMITATIONS[@]:-}"; do
        if [[ "${existing}" == "${note}" ]]; then
            return 0
        fi
    done
    RUNTIME_LIMITATIONS+=("${note}")
}

check_command() {
    local label="$1"
    local cmd="$2"
    local pkg="$3"

    if command -v "${cmd}" >/dev/null 2>&1; then
        log INFO "${label}: found (${cmd})"
        append_summary "tool.${cmd}=present"
        command_version_line "${cmd}" | sed 's/^/  version: /'
    else
        log WARN "${label}: missing (${cmd}), suggested apt package: ${pkg}"
        append_summary "tool.${cmd}=missing"
        add_missing_package "${pkg}"
    fi
}

check_dpkg_package() {
    local pkg="$1"
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
        log INFO "Package present: ${pkg}"
        append_summary "package.${pkg}=present"
    else
        log WARN "Package missing: ${pkg}"
        append_summary "package.${pkg}=missing"
        add_missing_package "${pkg}"
    fi
}

check_pkg_config_module() {
    local module="$1"
    local pkg="$2"

    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "${module}"; then
        log INFO "pkg-config module present: ${module}"
        append_summary "pkgconfig.${module}=present"
    else
        log WARN "pkg-config module missing: ${module} (suggested apt package: ${pkg})"
        append_summary "pkgconfig.${module}=missing"
        add_missing_package "${pkg}"
    fi
}

check_first_available_webkit_runtime_package() {
    local pkg=""
    pkg="$(select_webkit_runtime_package || true)"

    if [[ -n "${pkg}" ]] && dpkg -s "${pkg}" >/dev/null 2>&1; then
        log INFO "Package present: ${pkg}"
        append_summary "package.${pkg}=present"
        append_summary "webkit_runtime_package=${pkg}"
        return 0
    fi

    if [[ -n "${pkg}" ]]; then
        log WARN "Package missing: ${pkg}"
        append_summary "package.${pkg}=missing"
        append_summary "webkit_runtime_package=${pkg}"
        add_missing_package "${pkg}"
        return 0
    fi

    log WARN "No supported WebKitGTK runtime package detected in apt cache; IDE embedded browser features may be unavailable"
    append_summary "webkit_runtime_package=unavailable"
}

check_first_available_freetype_dev_package() {
    local pkg=""
    pkg="$(select_freetype_dev_package || true)"

    if [[ -n "${pkg}" ]] && dpkg -s "${pkg}" >/dev/null 2>&1; then
        log INFO "Package present: ${pkg}"
        append_summary "package.${pkg}=present"
        append_summary "freetype_dev_package=${pkg}"
        return 0
    fi

    if [[ -n "${pkg}" ]]; then
        log WARN "Package missing: ${pkg}"
        append_summary "package.${pkg}=missing"
        append_summary "freetype_dev_package=${pkg}"
        add_missing_package "${pkg}"
        return 0
    fi

    log WARN "No supported FreeType development package detected in apt cache; OpenSceneGraph build may fail later"
    append_summary "freetype_dev_package=unavailable"
}

set_checkpoint "inspect" "collecting host and dependency information"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    log INFO "OS: ${PRETTY_NAME:-unknown}"
    append_summary "os=${PRETTY_NAME:-unknown}"
fi

log INFO "Kernel: $(uname -srmo)"
append_summary "kernel=$(uname -srmo)"

if grep -qi microsoft /proc/version 2>/dev/null || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    log INFO "WSL detected: yes"
    append_summary "wsl=yes"
else
    log INFO "WSL detected: no"
    append_summary "wsl=no"
fi

check_command "GNU C compiler" "gcc" "build-essential"
check_command "GNU C++ compiler" "g++" "build-essential"
check_command "Clang compiler" "clang" "clang"
check_command "CMake" "cmake" "cmake"
check_command "Git" "git" "git"
check_command "Java runtime" "java" "default-jre"
check_command "Java compiler" "javac" "default-jdk"
check_command "Python 3" "python3" "python3"
check_command "Python alias" "python" "python-is-python3"
check_command "Make" "make" "build-essential"
check_command "Bison" "bison" "bison"
check_command "Flex" "flex" "flex"
check_command "pkg-config" "pkg-config" "pkg-config"
check_command "qmake" "qmake" "qt5-qmake"
check_command "moc" "moc" "qtbase5-dev-tools"
check_command "uic" "uic" "qtbase5-dev-tools"
check_command "OpenGL info tool" "glxinfo" "mesa-utils"

set_checkpoint "qt_gl_checks" "checking Qt and OpenGL related development packages"

check_dpkg_package "qtbase5-dev"
check_dpkg_package "qtchooser"
check_dpkg_package "qt5-qmake"
check_dpkg_package "qtbase5-dev-tools"
check_dpkg_package "libqt5opengl5-dev"
check_first_available_webkit_runtime_package
check_dpkg_package "xcursor-themes"
check_dpkg_package "libgl1-mesa-dev"
check_dpkg_package "libglu1-mesa-dev"
check_dpkg_package "freeglut3-dev"
check_dpkg_package "mesa-utils"
check_dpkg_package "libxrandr-dev"
check_dpkg_package "libxinerama-dev"
check_dpkg_package "libxcursor-dev"
check_dpkg_package "libxi-dev"
check_dpkg_package "libxmu-dev"
check_dpkg_package "libjpeg-dev"
check_dpkg_package "libpng-dev"
check_dpkg_package "libtiff-dev"
check_first_available_freetype_dev_package

check_pkg_config_module "Qt5Core" "qtbase5-dev"
check_pkg_config_module "Qt5OpenGL" "libqt5opengl5-dev"
check_pkg_config_module "gl" "libgl1-mesa-dev"
check_pkg_config_module "glu" "libglu1-mesa-dev"

set_checkpoint "runtime_probe" "probing GLX runtime availability"

if command -v glxinfo >/dev/null 2>&1; then
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        if glxinfo -B >/dev/null 2>&1; then
            log INFO "glxinfo -B succeeded"
            append_summary "glxinfo=ok"
        else
            log WARN "glxinfo -B failed; treat as runtime limitation in WSL unless later build errors prove otherwise"
            append_summary "glxinfo=failed"
            add_runtime_limitation "glxinfo -B failed in current shell; possible WSLg/GUI/OpenGL limitation"
        fi
    else
        log WARN "DISPLAY/WAYLAND_DISPLAY not set; skipping GLX runtime probe"
        append_summary "glxinfo=skipped_no_display"
        add_runtime_limitation "No DISPLAY/WAYLAND_DISPLAY in current shell; GUI runtime checks skipped"
    fi
else
    log WARN "glxinfo not available; runtime probe skipped"
    append_summary "glxinfo=skipped_missing_tool"
fi

printf "\nMissing apt packages (%d):\n" "${#MISSING_PACKAGES[@]}"
if [[ "${#MISSING_PACKAGES[@]}" -eq 0 ]]; then
    printf "  - none\n"
    append_summary "missing_packages_count=0"
else
    append_summary "missing_packages_count=${#MISSING_PACKAGES[@]}"
    for pkg in "${MISSING_PACKAGES[@]}"; do
        printf "  - %s\n" "${pkg}"
        append_summary "missing_package=${pkg}"
    done
fi

printf "\nRecorded runtime limitations (%d):\n" "${#RUNTIME_LIMITATIONS[@]}"
if [[ "${#RUNTIME_LIMITATIONS[@]}" -eq 0 ]]; then
    printf "  - none\n"
    append_summary "runtime_limitations_count=0"
else
    append_summary "runtime_limitations_count=${#RUNTIME_LIMITATIONS[@]}"
    for note in "${RUNTIME_LIMITATIONS[@]}"; do
        printf "  - %s\n" "${note}"
        append_summary "runtime_limitation=${note}"
    done
fi

stage_mark_success "Environment snapshot collected; missing packages count=${#MISSING_PACKAGES[@]}"
