#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "30" "build_osgearth_27_method_a"
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
        stage_mark_failure "Required command '${cmd}' is missing. Install package '${pkg}' and rerun Stage 30."
    fi
}

check_package() {
    local pkg="$1"
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
        MISSING_APT_PACKAGES+=("${pkg}")
    fi
}

have_any_glob() {
    local pattern
    for pattern in "$@"; do
        if compgen -G "${pattern}" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

check_system_dependency() {
    local dep_name="$1"
    local pkg_name="$2"
    local header_globs_raw="$3"
    shift 3
    local aux_evidence=("$@")
    local -a header_globs=()
    IFS=';' read -r -a header_globs <<< "${header_globs_raw}"

    local pkg_installed="no"
    if dpkg -s "${pkg_name}" >/dev/null 2>&1; then
        pkg_installed="yes"
    else
        MISSING_APT_PACKAGES+=("${pkg_name}")
    fi

    local have_header="no"
    local have_aux="no"
    if have_any_glob "${header_globs[@]}"; then
        have_header="yes"
    fi
    if have_any_glob "${aux_evidence[@]}"; then
        have_aux="yes"
    fi

    append_summary "dependency.${dep_name}.header=${have_header}"
    append_summary "dependency.${dep_name}.aux=${have_aux}"
    append_summary "dependency.${dep_name}.package=${pkg_name}"
    append_summary "dependency.${dep_name}.package_installed=${pkg_installed}"

    if [[ "${have_header}" == "yes" ]] && [[ "${have_aux}" == "yes" ]]; then
        append_summary "dependency.${dep_name}.evidence=present"
        return 0
    fi

    append_summary "dependency.${dep_name}.evidence=missing"
    MISSING_SYSTEM_DEPS+=("${dep_name}")
    return 1
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

if [[ ! -d "${OSGEARTH_SOURCE_DIR}/.git" ]]; then
    stage_mark_failure "osgEarth source tree is missing at ${OSGEARTH_SOURCE_DIR}. Run Stage 10 first."
fi

if [[ ! -e "${OPENSCENEGRAPH_PREFIX}/lib/libosg.so" ]]; then
    stage_mark_failure "OpenSceneGraph local install is missing at ${OPENSCENEGRAPH_PREFIX}. Run Stage 20 first."
fi

if [[ "$(git -C "${OSGEARTH_SOURCE_DIR}" rev-parse HEAD)" != "${OSGEARTH_COMMIT}" ]]; then
    stage_mark_failure "osgEarth source tree at ${OSGEARTH_SOURCE_DIR} is not pinned to ${OSGEARTH_COMMIT}. Re-run Stage 10."
fi

OSGEARTH_INTERNAL_VERSION="$(
    awk '
        /SET\(OSGEARTH_MAJOR_VERSION/ { gsub(/\)/, "", $2); major=$2 }
        /SET\(OSGEARTH_MINOR_VERSION/ { gsub(/\)/, "", $2); minor=$2 }
        /SET\(OSGEARTH_PATCH_VERSION/ { gsub(/\)/, "", $2); patch=$2 }
        END { if (major != "" && minor != "" && patch != "") print major "." minor "." patch }
    ' "${OSGEARTH_SOURCE_DIR}/CMakeLists.txt"
)"

declare -a MISSING_APT_PACKAGES=()
declare -a MISSING_SYSTEM_DEPS=()
declare -a STAGE30_BASE_APT_PACKAGES=(
    build-essential
    cmake
    pkg-config
    zlib1g-dev
)

append_summary "method=official_build_doc_adapted"
append_summary "osgearth_ref=${OSGEARTH_REF_METHOD_A}"
append_summary "osgearth_commit=${OSGEARTH_COMMIT}"
append_summary "osgearth_internal_version=${OSGEARTH_INTERNAL_VERSION:-unknown}"
append_summary "compat_patch=${OSGEARTH_27_COMPAT_PATCH}"
append_summary "official_doc_note=latest_docs_are_3x_series"
append_summary "official_doc_reused=out_of_source_cmake_local_prefix_explicit_dependency_checks"
append_summary "official_doc_adjusted_for_27=use_OSG_DIR_disable_Qt_skip_GLEW_keep_bundled_tinyxml"

set_checkpoint "patch" "ensuring osgEarth 2.7 compatibility patch is applied"
ensure_git_patch_applied "${OSGEARTH_SOURCE_DIR}" "${OSGEARTH_27_COMPAT_PATCH}" "osgearth_27_osg36_gcc9_compat"

set_checkpoint "preflight" "checking prerequisites for osgEarth 2.7 Method A"

for pkg in "${STAGE30_BASE_APT_PACKAGES[@]}"; do
    check_package "${pkg}"
done

check_system_dependency "curl" "libcurl4-openssl-dev" \
    "/usr/include/curl/curl.h;/usr/include/x86_64-linux-gnu/curl/curl.h" \
    "/usr/lib/x86_64-linux-gnu/libcurl.so*" \
    "/usr/lib/libcurl.so*" \
    "/usr/bin/curl-config" \
    "/usr/lib*/pkgconfig/libcurl.pc" || true

check_system_dependency "gdal" "libgdal-dev" \
    "/usr/include/gdal/gdal.h" \
    "/usr/lib/x86_64-linux-gnu/libgdal.so*" \
    "/usr/lib/libgdal.so*" \
    "/usr/bin/gdal-config" \
    "/usr/lib*/pkgconfig/gdal.pc" || true

check_system_dependency "geos" "libgeos-dev" \
    "/usr/include/geos_c.h" \
    "/usr/lib/x86_64-linux-gnu/libgeos.so*" \
    "/usr/lib/libgeos.so*" \
    "/usr/bin/geos-config" \
    "/usr/lib*/pkgconfig/geos.pc" || true

check_system_dependency "sqlite3" "libsqlite3-dev" \
    "/usr/include/sqlite3.h" \
    "/usr/lib/x86_64-linux-gnu/libsqlite3.so*" \
    "/usr/lib/libsqlite3.so*" \
    "/usr/lib*/pkgconfig/sqlite3.pc" || true

if [[ "${#MISSING_APT_PACKAGES[@]}" -gt 0 ]] || [[ "${#MISSING_SYSTEM_DEPS[@]}" -gt 0 ]]; then
    append_summary "apt_install.required=yes"
    append_summary "apt_install.missing_count=${#MISSING_APT_PACKAGES[@]}"
    append_summary "dependency.missing_count=${#MISSING_SYSTEM_DEPS[@]}"
    if [[ "${#MISSING_APT_PACKAGES[@]}" -gt 0 ]]; then
        log WARN "Stage 30 missing apt packages: ${MISSING_APT_PACKAGES[*]}"
    fi
    if [[ "${#MISSING_SYSTEM_DEPS[@]}" -gt 0 ]]; then
        log WARN "Stage 30 missing dependency evidence: ${MISSING_SYSTEM_DEPS[*]}"
    fi
    for pkg in "${MISSING_APT_PACKAGES[@]}"; do
        append_summary "apt_install.missing_package=${pkg}"
    done
    for dep in "${MISSING_SYSTEM_DEPS[@]}"; do
        append_summary "dependency.missing=${dep}"
    done

    if [[ "${STAGE30_AUTO_APT:-0}" != "1" ]]; then
        stage_mark_failure "Missing osgEarth 2.7 Method A prerequisites. Missing packages: ${MISSING_APT_PACKAGES[*]:-none}. Missing dependency evidence: ${MISSING_SYSTEM_DEPS[*]:-none}. Install them in this WSL instance and rerun Stage 30."
    fi

    need_command "sudo" "sudo"
    need_command "apt-get" "apt"

    if ! sudo -n true >/dev/null 2>&1; then
        stage_mark_failure "Missing Stage 30 prerequisites. Packages needing install: ${MISSING_APT_PACKAGES[*]:-none}. Automatic install was requested, but passwordless sudo is not available in this shell."
    fi

    set_checkpoint "apt_install" "installing missing apt prerequisites for osgEarth 2.7 Method A"
    log INFO "Installing missing apt packages: ${MISSING_APT_PACKAGES[*]}"
    if [[ "${#MISSING_APT_PACKAGES[@]}" -gt 0 ]]; then
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_APT_PACKAGES[@]}"
    fi
    append_summary "apt_install.performed=yes"
else
    append_summary "apt_install.required=no"
fi

need_command "cmake" "cmake"
need_command "make" "build-essential"
need_command "gcc" "build-essential"
need_command "g++" "build-essential"
need_command "pkg-config" "pkg-config"

mkdir -p "${OSGEARTH_27A_BUILD_DIR}" "${OSGEARTH_27A_PREFIX}"

export OSG_DIR="${OPENSCENEGRAPH_PREFIX}"
export PATH="${OPENSCENEGRAPH_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OPENSCENEGRAPH_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

declare -a CMAKE_ARGS=(
    -S "${OSGEARTH_SOURCE_DIR}"
    -B "${OSGEARTH_27A_BUILD_DIR}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${OSGEARTH_27A_PREFIX}"
    -DCMAKE_PREFIX_PATH="${OPENSCENEGRAPH_PREFIX}"
    -DCMAKE_INCLUDE_PATH="${OPENSCENEGRAPH_PREFIX}/include"
    -DCMAKE_LIBRARY_PATH="${OPENSCENEGRAPH_PREFIX}/lib"
    -DOSG_DIR="${OPENSCENEGRAPH_PREFIX}"
    -DOSGEARTH_USE_QT=OFF
    -DOSGEARTH_INSTALL_SHADERS=ON
    -DDYNAMIC_OSGEARTH=ON
    -DINSTALL_TO_OSG_DIR=OFF
    -DWITH_EXTERNAL_TINYXML=OFF
    -DENABLE_FASTDXT=OFF
)

append_summary "install_prefix=${OSGEARTH_27A_PREFIX}"
append_summary "build_dir=${OSGEARTH_27A_BUILD_DIR}"
append_summary "source_dir=${OSGEARTH_SOURCE_DIR}"
append_summary "osg_dir=${OPENSCENEGRAPH_PREFIX}"
append_summary "build_jobs=${BUILD_JOBS}"
append_summary "cmake_arg.OSGEARTH_USE_QT=OFF"
append_summary "cmake_arg.OSGEARTH_INSTALL_SHADERS=ON"
append_summary "cmake_arg.DYNAMIC_OSGEARTH=ON"
append_summary "cmake_arg.INSTALL_TO_OSG_DIR=OFF"
append_summary "cmake_arg.WITH_EXTERNAL_TINYXML=OFF"
append_summary "cmake_arg.ENABLE_FASTDXT=OFF"

set_checkpoint "configure" "configuring osgEarth 2.7 Method A build"
cmake "${CMAKE_ARGS[@]}"

set_checkpoint "build" "building osgEarth 2.7 Method A"
cmake --build "${OSGEARTH_27A_BUILD_DIR}" --parallel "${BUILD_JOBS}"

set_checkpoint "install" "installing osgEarth 2.7 Method A to local prefix"
cmake --install "${OSGEARTH_27A_BUILD_DIR}"

set_checkpoint "runtime_data" "installing osgEarth runtime data assets required by estnet"
OSGEARTH_RUNTIME_DATA_DIR="${OSGEARTH_27A_PREFIX}/data"
mkdir -p "${OSGEARTH_RUNTIME_DATA_DIR}"
verify_artifact "${OSGEARTH_SOURCE_DIR}/data/moon_1024x512.jpg" "osgEarth moon texture source asset"
cp "${OSGEARTH_SOURCE_DIR}/data/moon_1024x512.jpg" "${OSGEARTH_RUNTIME_DATA_DIR}/moon_1024x512.jpg"

OSGEARTH_PLUGIN_DIR="$(find "${OSGEARTH_27A_PREFIX}" -maxdepth 3 -type d -name "osgPlugins-*" | sort | head -n1)"
OSGEARTH_LIBRARY_PATH="$(find "${OSGEARTH_27A_PREFIX}" -maxdepth 3 -name "libosgEarth.so" | sort | head -n1)"

verify_artifact "${OSGEARTH_27A_PREFIX}/include/osgEarth/Version" "osgEarth header"
if [[ -z "${OSGEARTH_LIBRARY_PATH}" ]]; then
    stage_mark_failure "osgEarth shared library was not installed under ${OSGEARTH_27A_PREFIX}"
fi
verify_artifact "${OSGEARTH_LIBRARY_PATH}" "osgEarth shared library"
if [[ -z "${OSGEARTH_PLUGIN_DIR}" ]]; then
    stage_mark_failure "osgEarth plugin directory was not installed under ${OSGEARTH_27A_PREFIX}"
fi

append_summary "installed_header=${OSGEARTH_27A_PREFIX}/include/osgEarth/Version"
append_summary "installed_library=${OSGEARTH_LIBRARY_PATH}"
append_summary "installed_plugin_dir=${OSGEARTH_PLUGIN_DIR}"
append_summary "installed_runtime_data_dir=${OSGEARTH_RUNTIME_DATA_DIR}"
append_summary "installed_runtime_data_asset=${OSGEARTH_RUNTIME_DATA_DIR}/moon_1024x512.jpg"

stage_mark_success "osgEarth ${OSGEARTH_REF_METHOD_A} Method A built and installed at ${OSGEARTH_27A_PREFIX}"
