#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "20" "build_openscenegraph"
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
        stage_mark_failure "Required command '${cmd}' is missing. Install package '${pkg}' and rerun Stage 20."
    fi
}

check_package() {
    local pkg="$1"
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
        MISSING_APT_PACKAGES+=("${pkg}")
    fi
}

verify_artifact() {
    local path="$1"
    local description="$2"
    if [[ ! -e "${path}" ]]; then
        stage_mark_failure "Missing expected ${description}: ${path}"
    fi
}

need_command "dpkg" "dpkg"
need_command "git" "git"

if [[ ! -d "${OPENSCENEGRAPH_SOURCE_DIR}/.git" ]]; then
    stage_mark_failure "OpenSceneGraph source tree is missing at ${OPENSCENEGRAPH_SOURCE_DIR}. Run Stage 10 first."
fi

declare -a MISSING_APT_PACKAGES=()
STAGE20_FREETYPE_PKG="$(select_freetype_dev_package || true)"
if [[ -z "${STAGE20_FREETYPE_PKG}" ]]; then
    stage_mark_failure "No supported FreeType development package detected in apt cache (expected libfreetype6-dev or libfreetype-dev)."
fi
declare -a STAGE20_APT_PACKAGES=(
    build-essential
    cmake
    pkg-config
    libgl1-mesa-dev
    libglu1-mesa-dev
    libxrandr-dev
    libxinerama-dev
    libxcursor-dev
    libxi-dev
    libxmu-dev
    libjpeg-dev
    libpng-dev
    libtiff-dev
    zlib1g-dev
    libfontconfig1-dev
)
STAGE20_APT_PACKAGES+=("${STAGE20_FREETYPE_PKG}")

set_checkpoint "preflight" "checking apt prerequisites for OpenSceneGraph build"
append_summary "apt_install.freetype_package=${STAGE20_FREETYPE_PKG}"

for pkg in "${STAGE20_APT_PACKAGES[@]}"; do
    check_package "${pkg}"
done

if [[ "${#MISSING_APT_PACKAGES[@]}" -gt 0 ]]; then
    append_summary "apt_install.required=yes"
    append_summary "apt_install.missing_count=${#MISSING_APT_PACKAGES[@]}"
    log WARN "Stage 20 missing apt packages: ${MISSING_APT_PACKAGES[*]}"
    for pkg in "${MISSING_APT_PACKAGES[@]}"; do
        append_summary "apt_install.missing_package=${pkg}"
    done

    if [[ "${STAGE20_AUTO_APT:-0}" != "1" ]]; then
        stage_mark_failure "Missing apt packages for OpenSceneGraph build: ${MISSING_APT_PACKAGES[*]}. Rerun with STAGE20_AUTO_APT=1 after granting apt privileges."
    fi

    need_command "sudo" "sudo"
    need_command "apt-get" "apt"

    if ! sudo -n true >/dev/null 2>&1; then
        stage_mark_failure "Missing apt packages for Stage 20: ${MISSING_APT_PACKAGES[*]}. Automatic install was requested, but passwordless sudo is not available in this shell."
    fi

    set_checkpoint "apt_install" "installing missing apt prerequisites"
    log INFO "Installing missing apt packages: ${MISSING_APT_PACKAGES[*]}"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_APT_PACKAGES[@]}"
    append_summary "apt_install.performed=yes"
else
    append_summary "apt_install.required=no"
fi

need_command "cmake" "cmake"
need_command "make" "build-essential"
need_command "gcc" "build-essential"
need_command "g++" "build-essential"
need_command "pkg-config" "pkg-config"

mkdir -p "${OPENSCENEGRAPH_BUILD_DIR}" "${OPENSCENEGRAPH_PREFIX}"

OSG_BUILD_OPENGL_PROFILE="${OSG_BUILD_OPENGL_PROFILE:-GL2}"
OSG_BUILD_GL_CONTEXT_VERSION="${OSG_BUILD_GL_CONTEXT_VERSION:-}"

declare -a CMAKE_ARGS=(
    -S "${OPENSCENEGRAPH_SOURCE_DIR}"
    -B "${OPENSCENEGRAPH_BUILD_DIR}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${OPENSCENEGRAPH_PREFIX}"
    -DOpenGL_GL_PREFERENCE=LEGACY
    -DOSG_WINDOWING_SYSTEM=X11
    -DOPENGL_PROFILE="${OSG_BUILD_OPENGL_PROFILE}"
    -DBUILD_OSG_APPLICATIONS=ON
    -DBUILD_OSG_EXAMPLES=OFF
    -DBUILD_OSG_PLUGINS=ON
    -DBUILD_DOCUMENTATION=OFF
    -DDYNAMIC_OPENSCENEGRAPH=ON
)

if [[ -n "${OSG_BUILD_GL_CONTEXT_VERSION}" ]]; then
    CMAKE_ARGS+=("-DOSG_GL_CONTEXT_VERSION=${OSG_BUILD_GL_CONTEXT_VERSION}")
fi

append_summary "install_prefix=${OPENSCENEGRAPH_PREFIX}"
append_summary "build_dir=${OPENSCENEGRAPH_BUILD_DIR}"
append_summary "source_dir=${OPENSCENEGRAPH_SOURCE_DIR}"
append_summary "build_jobs=${BUILD_JOBS}"
append_summary "cmake_arg.OPENGL_PROFILE=${OSG_BUILD_OPENGL_PROFILE}"
append_summary "cmake_arg.OSG_WINDOWING_SYSTEM=X11"
append_summary "cmake_arg.BUILD_OSG_APPLICATIONS=ON"
append_summary "cmake_arg.BUILD_OSG_EXAMPLES=OFF"
append_summary "cmake_arg.BUILD_OSG_PLUGINS=ON"
append_summary "cmake_arg.BUILD_DOCUMENTATION=OFF"
append_summary "cmake_arg.DYNAMIC_OPENSCENEGRAPH=ON"
if [[ -n "${OSG_BUILD_GL_CONTEXT_VERSION}" ]]; then
    append_summary "cmake_arg.OSG_GL_CONTEXT_VERSION=${OSG_BUILD_GL_CONTEXT_VERSION}"
fi

set_checkpoint "configure" "configuring OpenSceneGraph build"
cmake "${CMAKE_ARGS[@]}"

set_checkpoint "build" "building OpenSceneGraph"
cmake --build "${OPENSCENEGRAPH_BUILD_DIR}" --parallel "${BUILD_JOBS}"

set_checkpoint "install" "installing OpenSceneGraph to local prefix"
cmake --install "${OPENSCENEGRAPH_BUILD_DIR}"

OPENSCENEGRAPH_PLUGIN_DIR="$(find "${OPENSCENEGRAPH_PREFIX}" -maxdepth 3 -type d -name "osgPlugins-*" | sort | head -n1)"

verify_artifact "${OPENSCENEGRAPH_PREFIX}/include/osg/Version" "OpenSceneGraph header"
verify_artifact "${OPENSCENEGRAPH_PREFIX}/lib/libosg.so" "OpenSceneGraph shared library"
if [[ -z "${OPENSCENEGRAPH_PLUGIN_DIR}" ]]; then
    stage_mark_failure "OpenSceneGraph plugin directory was not installed under ${OPENSCENEGRAPH_PREFIX}"
fi

append_summary "installed_header=${OPENSCENEGRAPH_PREFIX}/include/osg/Version"
append_summary "installed_library=${OPENSCENEGRAPH_PREFIX}/lib/libosg.so"
append_summary "installed_plugin_dir=${OPENSCENEGRAPH_PLUGIN_DIR}"

stage_mark_success "OpenSceneGraph ${OPENSCENEGRAPH_VERSION} built and installed at ${OPENSCENEGRAPH_PREFIX}"
