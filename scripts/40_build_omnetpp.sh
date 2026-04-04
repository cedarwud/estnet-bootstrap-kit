#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "40" "build_omnetpp"
trap 'handle_unexpected_error $? ${LINENO} "${BASH_COMMAND}"' ERR

if stage_should_skip; then
    exit 0
fi

stage_begin_work

declare -a MISSING_PACKAGES=()

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

check_dpkg_package() {
    local pkg="$1"
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
        append_summary "package.${pkg}=present"
    else
        append_summary "package.${pkg}=missing"
        add_missing_package "${pkg}"
    fi
}

find_first_command() {
    local cmd
    for cmd in "$@"; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            printf "%s\n" "${cmd}"
            return 0
        fi
    done
    return 1
}

require_any_command() {
    local label="$1"
    local pkg="$2"
    shift 2
    local resolved
    if resolved="$(find_first_command "$@")"; then
        append_summary "tool.${label}=${resolved}"
    else
        append_summary "tool.${label}=missing"
        add_missing_package "${pkg}"
    fi
}

check_pkg_config_module() {
    local module="$1"
    local pkg="$2"
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "${module}"; then
        append_summary "pkgconfig.${module}=present"
    else
        append_summary "pkgconfig.${module}=missing"
        add_missing_package "${pkg}"
    fi
}

set_or_add_config_var() {
    local file="$1"
    local key="$2"
    local value="$3"
    local temp_file
    temp_file="$(mktemp)"
    awk -v key="${key}" -v value="${value}" '
        BEGIN { replaced=0 }
        $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" {
            if (!replaced) {
                print key "=" value
                replaced=1
            }
            next
        }
        { print }
        END {
            if (!replaced)
                print key "=" value
        }
    ' "${file}" > "${temp_file}"
    mv "${temp_file}" "${file}"
}

verify_config_assignment() {
    local file="$1"
    local expected_line="$2"
    if ! grep -Fxq "${expected_line}" "${file}"; then
        stage_mark_failure "Expected configure.user assignment not found: ${expected_line}"
    fi
}

verify_makefile_setting() {
    local file="$1"
    local expected_line="$2"
    if ! grep -Fxq "${expected_line}" "${file}"; then
        stage_mark_failure "Expected Makefile.inc setting not found: ${expected_line}"
    fi
}

resolve_library_dir() {
    local prefix="$1"
    local library_name="$2"
    local library_path
    library_path="$(find "${prefix}" -maxdepth 3 -name "${library_name}" | sort | head -n1)"
    if [[ -z "${library_path}" ]]; then
        stage_mark_failure "Could not find ${library_name} under ${prefix}"
    fi
    dirname "${library_path}"
}

need_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        stage_mark_failure "Required command '${cmd}' is missing. Install package '${pkg}' and rerun Stage 40."
    fi
}

need_command "dpkg" "dpkg"
need_command "git" "git"
need_command "grep" "grep"
need_command "awk" "gawk"
need_command "find" "findutils"
need_command "mktemp" "coreutils"

if [[ ! -d "${OMNETPP_DIR}/.git" ]]; then
    stage_mark_failure "OMNeT++ source tree is missing at ${OMNETPP_DIR}. Run Stage 10 first."
fi

if [[ "$(git -C "${OMNETPP_DIR}" rev-parse HEAD)" != "${OMNETPP_COMMIT}" ]]; then
    stage_mark_failure "OMNeT++ source tree at ${OMNETPP_DIR} is not pinned to ${OMNETPP_COMMIT}. Re-run Stage 10."
fi

if [[ ! -e "${OPENSCENEGRAPH_PREFIX}/lib/libosg.so" ]]; then
    stage_mark_failure "OpenSceneGraph local install is missing at ${OPENSCENEGRAPH_PREFIX}. Run Stage 20 first."
fi

OMNETPP_OSGEARTH_METHOD="${OMNETPP_OSGEARTH_METHOD:-a}"
case "${OMNETPP_OSGEARTH_METHOD}" in
    a)
        SELECTED_OSGEARTH_PREFIX="${OSGEARTH_27A_PREFIX}"
        ;;
    b)
        SELECTED_OSGEARTH_PREFIX="${OSGEARTH_27B_PREFIX}"
        ;;
    *)
        stage_mark_failure "Unsupported OMNETPP_OSGEARTH_METHOD='${OMNETPP_OSGEARTH_METHOD}'. Use 'a' or 'b'."
        ;;
esac

if [[ ! -d "${SELECTED_OSGEARTH_PREFIX}" ]]; then
    stage_mark_failure "Selected osgEarth prefix is missing at ${SELECTED_OSGEARTH_PREFIX}. Run Stage 30 or Stage 31 first."
fi

OSG_LIBDIR="$(resolve_library_dir "${OPENSCENEGRAPH_PREFIX}" "libosg.so")"
OSGEARTH_LIBDIR="$(resolve_library_dir "${SELECTED_OSGEARTH_PREFIX}" "libosgEarth.so")"
CONFIGURE_USER_FILE="${OMNETPP_DIR}/configure.user"
CONFIGURE_CAPTURE="${LOG_DIR}/40_build_omnetpp.configure.${RUN_TS}.log"
MAKEFILE_INC="${OMNETPP_DIR}/Makefile.inc"

append_summary "required_config=PREFER_CLANG=no,PREFER_SQLITE_RESULT_FILES=yes,WITH_OSG=yes,WITH_OSGEARTH=yes"
append_summary "osgearth_method=${OMNETPP_OSGEARTH_METHOD}"
append_summary "osg_prefix=${OPENSCENEGRAPH_PREFIX}"
append_summary "osg_libdir=${OSG_LIBDIR}"
append_summary "osgearth_prefix=${SELECTED_OSGEARTH_PREFIX}"
append_summary "osgearth_libdir=${OSGEARTH_LIBDIR}"
append_summary "compat_patch=${OMNETPP_551_OSG_CFLAGS_PATCH}"
append_summary "configure_capture=${CONFIGURE_CAPTURE}"

set_checkpoint "patch" "ensuring OMNeT++ local OSG include patch is applied"
ensure_git_patch_applied "${OMNETPP_DIR}" "${OMNETPP_551_OSG_CFLAGS_PATCH}" "omnetpp_551_local_osg_cflags"

set_checkpoint "configure_user" "creating or updating configure.user"

if [[ ! -f "${CONFIGURE_USER_FILE}" ]]; then
    cp "${OMNETPP_DIR}/configure.user.dist" "${CONFIGURE_USER_FILE}"
    append_summary "configure_user.created=yes"
else
    append_summary "configure_user.created=no"
fi

set_or_add_config_var "${CONFIGURE_USER_FILE}" "PREFER_CLANG" "no"
set_or_add_config_var "${CONFIGURE_USER_FILE}" "PREFER_SQLITE_RESULT_FILES" "yes"
set_or_add_config_var "${CONFIGURE_USER_FILE}" "WITH_OSG" "yes"
set_or_add_config_var "${CONFIGURE_USER_FILE}" "WITH_OSGEARTH" "yes"
set_or_add_config_var "${CONFIGURE_USER_FILE}" "OSG_CFLAGS" "\"-I${OPENSCENEGRAPH_PREFIX}/include\""
set_or_add_config_var "${CONFIGURE_USER_FILE}" "OSG_LIBS" "\"-L${OSG_LIBDIR} -losg -losgDB -losgGA -losgViewer -losgUtil -lOpenThreads\""
set_or_add_config_var "${CONFIGURE_USER_FILE}" "OSGEARTH_CFLAGS" "\"-I${OPENSCENEGRAPH_PREFIX}/include -I${SELECTED_OSGEARTH_PREFIX}/include\""
set_or_add_config_var "${CONFIGURE_USER_FILE}" "OSGEARTH_LIBS" "\"-L${OSGEARTH_LIBDIR} -losgEarth -losgEarthUtil\""

verify_config_assignment "${CONFIGURE_USER_FILE}" "PREFER_CLANG=no"
verify_config_assignment "${CONFIGURE_USER_FILE}" "PREFER_SQLITE_RESULT_FILES=yes"
verify_config_assignment "${CONFIGURE_USER_FILE}" "WITH_OSG=yes"
verify_config_assignment "${CONFIGURE_USER_FILE}" "WITH_OSGEARTH=yes"

append_summary "configure_user.path=${CONFIGURE_USER_FILE}"
append_summary "configure_user.osg_cflags=-I${OPENSCENEGRAPH_PREFIX}/include"
append_summary "configure_user.osg_libs=-L${OSG_LIBDIR} -losg -losgDB -losgGA -losgViewer -losgUtil -lOpenThreads"
append_summary "configure_user.osgearth_cflags=-I${OPENSCENEGRAPH_PREFIX}/include -I${SELECTED_OSGEARTH_PREFIX}/include"
append_summary "configure_user.osgearth_libs=-L${OSGEARTH_LIBDIR} -losgEarth -losgEarthUtil"

set_checkpoint "preflight" "checking OMNeT++ build prerequisites"

check_dpkg_package "default-jre"
check_dpkg_package "default-jdk"
check_dpkg_package "bison"
check_dpkg_package "flex"
check_dpkg_package "qtbase5-dev"
check_dpkg_package "qtchooser"
check_dpkg_package "qt5-qmake"
check_dpkg_package "qtbase5-dev-tools"
check_dpkg_package "libqt5opengl5-dev"

require_any_command "java" "default-jre" java
require_any_command "javac" "default-jdk" javac
require_any_command "bison" "bison" bison
require_any_command "flex" "flex" flex
require_any_command "qmake" "qt5-qmake" qmake qmake-qt5 qmake5
require_any_command "moc" "qtbase5-dev-tools" moc moc-qt5 moc5
require_any_command "uic" "qtbase5-dev-tools" uic uic-qt5 uic5

check_pkg_config_module "Qt5Core" "qtbase5-dev"
check_pkg_config_module "Qt5OpenGL" "libqt5opengl5-dev"

if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
    append_summary "missing_packages_count=${#MISSING_PACKAGES[@]}"
    for pkg in "${MISSING_PACKAGES[@]}"; do
        append_summary "missing_package=${pkg}"
    done
    stage_mark_failure "Missing OMNeT++ build prerequisites in this WSL instance: ${MISSING_PACKAGES[*]}. Install them and rerun Stage 40."
fi

export PATH="${OMNETPP_DIR}/bin:${OPENSCENEGRAPH_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OSGEARTH_LIBDIR}:${OSG_LIBDIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
append_summary "runtime_path.bin=${OMNETPP_DIR}/bin"

set_checkpoint "configure" "running OMNeT++ configure"
(
    cd "${OMNETPP_DIR}"
    ./configure | tee "${CONFIGURE_CAPTURE}"
)

if ! grep -E "checking for OpenSceneGraph .*yes" "${CONFIGURE_CAPTURE}" >/dev/null 2>&1; then
    stage_mark_failure "OMNeT++ configure did not report a successful OpenSceneGraph check. Inspect ${CONFIGURE_CAPTURE}."
fi
if ! grep -E "checking for osgEarth .*yes" "${CONFIGURE_CAPTURE}" >/dev/null 2>&1; then
    stage_mark_failure "OMNeT++ configure did not report a successful osgEarth check. Inspect ${CONFIGURE_CAPTURE}."
fi

if [[ ! -f "${MAKEFILE_INC}" ]]; then
    stage_mark_failure "OMNeT++ configure did not generate ${MAKEFILE_INC}"
fi

verify_makefile_setting "${MAKEFILE_INC}" "WITH_OSG ?= yes"
verify_makefile_setting "${MAKEFILE_INC}" "WITH_OSGEARTH ?= yes"
verify_makefile_setting "${MAKEFILE_INC}" "PREFER_SQLITE_RESULT_FILES ?= yes"

append_summary "configure_check.openscenegraph=yes"
append_summary "configure_check.osgearth=yes"
append_summary "makefile_inc.path=${MAKEFILE_INC}"

set_checkpoint "build" "building OMNeT++"
(
    cd "${OMNETPP_DIR}"
    make -j"${BUILD_JOBS}"
)

OPP_RUN_PATH="$(find "${OMNETPP_DIR}" -maxdepth 3 -type f -name "opp_run" | sort | head -n1)"
QTENV_OSG_LIB_PATH="$(find "${OMNETPP_DIR}" -maxdepth 5 -type f -name "*oppqtenv-osg*.so*" | sort | head -n1)"

if [[ -z "${OPP_RUN_PATH}" ]]; then
    stage_mark_failure "OMNeT++ build completed but opp_run was not found under ${OMNETPP_DIR}"
fi
if [[ -z "${QTENV_OSG_LIB_PATH}" ]]; then
    stage_mark_failure "OMNeT++ build completed but qtenv OSG support library was not found under ${OMNETPP_DIR}"
fi

append_summary "artifact.opp_run=${OPP_RUN_PATH}"
append_summary "artifact.qtenv_osg=${QTENV_OSG_LIB_PATH}"
stage_mark_success "OMNeT++ ${OMNETPP_VERSION} configured and built with OSG/osgEarth support using Method ${OMNETPP_OSGEARTH_METHOD}."
