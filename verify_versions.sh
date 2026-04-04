#!/usr/bin/env bash
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT
source "${PROJECT_ROOT}/scripts/common.sh"

REPORT_FILE="${STATE_DIR}/version-verification.md"
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
SUMMARY_ROWS=""

summary_value() {
    local key="$1"
    local file="$2"
    [[ -f "${file}" ]] || return 0
    sed -n "s/^${key}=//p" "${file}" | head -n1
}

append() {
    printf "%s\n" "$*" >> "${REPORT_FILE}"
}

record_check() {
    local name="$1"
    local status="$2"
    local details="$3"

    case "${status}" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac

    SUMMARY_ROWS="${SUMMARY_ROWS}| ${name} | ${status} | ${details} |\n"
}

git_check() {
    local label="$1"
    local repo_dir="$2"
    local expected_commit="$3"
    local expected_ref="$4"
    local actual_commit actual_describe result details

    if [[ ! -d "${repo_dir}/.git" ]] && ! git -C "${repo_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        record_check "${label} source" "FAIL" "missing repository: ${repo_dir}"
        append "### ${label}"
        append ""
        append "- path: \`${repo_dir}\`"
        append "- result: FAIL"
        append "- reason: repository missing"
        append ""
        return 0
    fi

    actual_commit="$(git -C "${repo_dir}" rev-parse HEAD 2>/dev/null || true)"
    actual_describe="$(git -C "${repo_dir}" describe --tags --always 2>/dev/null || true)"
    result="PASS"
    details="commit=${actual_commit}, describe=${actual_describe}"
    if [[ -z "${actual_commit}" ]]; then
        result="FAIL"
        details="unable to resolve git commit"
    elif [[ "${actual_commit}" != "${expected_commit}" ]]; then
        result="FAIL"
        details="expected ${expected_commit}, got ${actual_commit}"
    fi
    record_check "${label} source" "${result}" "${details}"

    append "### ${label}"
    append ""
    append "- path: \`${repo_dir}\`"
    append "- expected_ref: \`${expected_ref}\`"
    append "- expected_commit: \`${expected_commit}\`"
    append "- actual_commit: \`${actual_commit:-unknown}\`"
    append "- actual_describe: \`${actual_describe:-unknown}\`"
    append "- result: ${result}"
    append ""
}

macro_value() {
    local macro="$1"
    local file="$2"
    [[ -f "${file}" ]] || return 0
    awk -v macro="${macro}" '$1 == "#define" && $2 == macro { print $3; exit }' "${file}"
}

ldd_capture() {
    local target="$1"
    local pattern="$2"
    if [[ ! -f "${PROJECT_ROOT}/activate_env.sh" ]]; then
        return 0
    fi
    bash -lc "source '${PROJECT_ROOT}/activate_env.sh' && ldd '${target}' | rg '${pattern}'" 2>/dev/null || true
}

check_line_value() {
    local label="$1"
    local expected="$2"
    local file="$3"
    local actual

    if [[ ! -f "${file}" ]]; then
        record_check "${label}" "FAIL" "missing file: ${file}"
        return 0
    fi

    actual="$(sed -n "s/^${label}=//p" "${file}" | head -n1)"
    if [[ "${actual}" == "${expected}" ]]; then
        record_check "${label}" "PASS" "${actual}"
    else
        record_check "${label}" "FAIL" "expected ${expected}, got ${actual:-missing}"
    fi
}

mkdir -p "${STATE_DIR}"
: > "${REPORT_FILE}"

ENV_KIND="$(detect_runtime_environment)"
DISTRO_ID="$(linux_distro_id || true)"
DISTRO_VERSION_ID="$(linux_distro_version_id || true)"
DISTRO_CODENAME="$(linux_distro_codename || true)"
VIRT_KIND="$(detect_virtualization || true)"

ACTIVE_OSGEARTH_METHOD="$(summary_value "osgearth_method" "${STATE_DIR}/40.summary")"
ACTIVE_OSGEARTH_PREFIX="$(summary_value "osgearth_prefix" "${STATE_DIR}/40.summary")"
ACTIVE_OSGEARTH_LIBDIR="$(summary_value "osgearth_libdir" "${STATE_DIR}/40.summary")"
if [[ -z "${ACTIVE_OSGEARTH_METHOD}" ]]; then
    if [[ -d "${OSGEARTH_27A_PREFIX}" ]]; then
        ACTIVE_OSGEARTH_METHOD="a"
        ACTIVE_OSGEARTH_PREFIX="${OSGEARTH_27A_PREFIX}"
        ACTIVE_OSGEARTH_LIBDIR="${OSGEARTH_27A_PREFIX}/lib64"
    elif [[ -d "${OSGEARTH_27B_PREFIX}" ]]; then
        ACTIVE_OSGEARTH_METHOD="b"
        ACTIVE_OSGEARTH_PREFIX="${OSGEARTH_27B_PREFIX}"
        ACTIVE_OSGEARTH_LIBDIR="${OSGEARTH_27B_PREFIX}/lib64"
    fi
fi

append "# Version Verification Report"
append ""
append "- generated_at: \`$(date "+%Y-%m-%d %H:%M:%S %z")\`"
append "- project_root: \`${PROJECT_ROOT}\`"
append "- environment: \`${ENV_KIND}\`"
append "- distro: \`${DISTRO_ID:-unknown}\`"
append "- distro_version: \`${DISTRO_VERSION_ID:-unknown}\`"
append "- distro_codename: \`${DISTRO_CODENAME:-unknown}\`"
append "- virtualization: \`${VIRT_KIND:-unknown}\`"
append ""
append "## Declared Pins"
append ""
append "| Component | Version | Ref | Commit |"
append "| --- | --- | --- | --- |"
append "| OMNeT++ | \`${OMNETPP_VERSION}\` | \`${OMNETPP_REF}\` | \`${OMNETPP_COMMIT}\` |"
append "| INET | \`${INET_VERSION}\` | \`${INET_REF}\` | \`${INET_COMMIT}\` |"
append "| OpenSceneGraph | \`${OPENSCENEGRAPH_VERSION}\` | \`${OPENSCENEGRAPH_REF}\` | \`${OPENSCENEGRAPH_COMMIT}\` |"
append "| osgEarth | \`${OSGEARTH_TARGET_SERIES}\` | \`${OSGEARTH_REF_METHOD_A}\` | \`${OSGEARTH_COMMIT}\` |"
append ""
append "## Source Repository Verification"
append ""

git_check "OMNeT++" "${OMNETPP_DIR}" "${OMNETPP_COMMIT}" "${OMNETPP_REF}"
git_check "INET" "${INET_DIR}" "${INET_COMMIT}" "${INET_REF}"
git_check "OpenSceneGraph" "${OPENSCENEGRAPH_SOURCE_DIR}" "${OPENSCENEGRAPH_COMMIT}" "${OPENSCENEGRAPH_REF}"
git_check "osgEarth" "${OSGEARTH_SOURCE_DIR}" "${OSGEARTH_COMMIT}" "${OSGEARTH_REF_METHOD_A}"

append "## Installed Header Verification"
append ""

OSG_VERSION_HEADER="${OPENSCENEGRAPH_PREFIX}/include/osg/Version"
OSGEARTH_VERSION_HEADER="${ACTIVE_OSGEARTH_PREFIX}/include/osgEarth/Version"

if [[ -f "${OSG_VERSION_HEADER}" ]]; then
    OSG_MAJOR="$(macro_value "OPENSCENEGRAPH_MAJOR_VERSION" "${OSG_VERSION_HEADER}")"
    OSG_MINOR="$(macro_value "OPENSCENEGRAPH_MINOR_VERSION" "${OSG_VERSION_HEADER}")"
    OSG_PATCH="$(macro_value "OPENSCENEGRAPH_PATCH_VERSION" "${OSG_VERSION_HEADER}")"
    if [[ "${OSG_MAJOR}.${OSG_MINOR}.${OSG_PATCH}" == "${OPENSCENEGRAPH_VERSION}" ]]; then
        record_check "OpenSceneGraph installed header" "PASS" "${OSG_MAJOR}.${OSG_MINOR}.${OSG_PATCH}"
    else
        record_check "OpenSceneGraph installed header" "FAIL" "expected ${OPENSCENEGRAPH_VERSION}, got ${OSG_MAJOR}.${OSG_MINOR}.${OSG_PATCH}"
    fi
    append "### OpenSceneGraph"
    append ""
    append "- header: \`${OSG_VERSION_HEADER}\`"
    append "- detected_version: \`${OSG_MAJOR}.${OSG_MINOR}.${OSG_PATCH}\`"
    append ""
else
    record_check "OpenSceneGraph installed header" "FAIL" "missing header: ${OSG_VERSION_HEADER}"
    append "### OpenSceneGraph"
    append ""
    append "- header: \`${OSG_VERSION_HEADER}\`"
    append "- result: FAIL"
    append ""
fi

if [[ -n "${ACTIVE_OSGEARTH_PREFIX}" && -f "${OSGEARTH_VERSION_HEADER}" ]]; then
    OSGEARTH_MAJOR="$(macro_value "OSGEARTH_MAJOR_VERSION" "${OSGEARTH_VERSION_HEADER}")"
    OSGEARTH_MINOR="$(macro_value "OSGEARTH_MINOR_VERSION" "${OSGEARTH_VERSION_HEADER}")"
    OSGEARTH_PATCH="$(macro_value "OSGEARTH_PATCH_VERSION" "${OSGEARTH_VERSION_HEADER}")"
    if [[ "${OSGEARTH_MAJOR}.${OSGEARTH_MINOR}.${OSGEARTH_PATCH}" == "2.7.0" ]]; then
        record_check "osgEarth installed header" "PASS" "${OSGEARTH_MAJOR}.${OSGEARTH_MINOR}.${OSGEARTH_PATCH}"
    else
        record_check "osgEarth installed header" "FAIL" "expected 2.7.0, got ${OSGEARTH_MAJOR}.${OSGEARTH_MINOR}.${OSGEARTH_PATCH}"
    fi
    append "### osgEarth"
    append ""
    append "- active_method: \`${ACTIVE_OSGEARTH_METHOD:-unknown}\`"
    append "- prefix: \`${ACTIVE_OSGEARTH_PREFIX}\`"
    append "- header: \`${OSGEARTH_VERSION_HEADER}\`"
    append "- detected_version: \`${OSGEARTH_MAJOR}.${OSGEARTH_MINOR}.${OSGEARTH_PATCH}\`"
    append ""
else
    record_check "osgEarth installed header" "FAIL" "missing header: ${OSGEARTH_VERSION_HEADER}"
    append "### osgEarth"
    append ""
    append "- active_method: \`${ACTIVE_OSGEARTH_METHOD:-unknown}\`"
    append "- prefix: \`${ACTIVE_OSGEARTH_PREFIX:-missing}\`"
    append "- header: \`${OSGEARTH_VERSION_HEADER}\`"
    append "- result: FAIL"
    append ""
fi

append "## OMNeT++ Configure Verification"
append ""

check_line_value "PREFER_CLANG" "no" "${OMNETPP_DIR}/configure.user"
check_line_value "PREFER_SQLITE_RESULT_FILES" "yes" "${OMNETPP_DIR}/configure.user"
check_line_value "WITH_OSG" "yes" "${OMNETPP_DIR}/configure.user"
check_line_value "WITH_OSGEARTH" "yes" "${OMNETPP_DIR}/configure.user"

CONFIGURE_OSG_CHECK="$(summary_value "configure_check.openscenegraph" "${STATE_DIR}/40.summary")"
CONFIGURE_OSGEARTH_CHECK="$(summary_value "configure_check.osgearth" "${STATE_DIR}/40.summary")"
if [[ "${CONFIGURE_OSG_CHECK}" == "yes" ]]; then
    record_check "configure_check.openscenegraph" "PASS" "yes"
else
    record_check "configure_check.openscenegraph" "FAIL" "${CONFIGURE_OSG_CHECK:-missing}"
fi
if [[ "${CONFIGURE_OSGEARTH_CHECK}" == "yes" ]]; then
    record_check "configure_check.osgearth" "PASS" "yes"
else
    record_check "configure_check.osgearth" "FAIL" "${CONFIGURE_OSGEARTH_CHECK:-missing}"
fi

append '```ini'
if [[ -f "${OMNETPP_DIR}/configure.user" ]]; then
    sed -n '/^PREFER_CLANG=/p;/^PREFER_SQLITE_RESULT_FILES=/p;/^WITH_OSG=/p;/^WITH_OSGEARTH=/p;/^OSG_CFLAGS=/p;/^OSG_LIBS=/p;/^OSGEARTH_CFLAGS=/p;/^OSGEARTH_LIBS=/p' "${OMNETPP_DIR}/configure.user" >> "${REPORT_FILE}"
else
    printf "# missing %s/configure.user\n" "${OMNETPP_DIR}" >> "${REPORT_FILE}"
fi
append '```'
append ""

append "## Runtime Link Verification"
append ""

QTENV_OSG_LIB="${OMNETPP_DIR}/lib/liboppqtenv-osg.so"
ESTNET_TEMPLATE_BIN="${ESTNET_TEMPLATE_DIR}/out/gcc-release/src/estnet"

if [[ -f "${PROJECT_ROOT}/activate_env.sh" && -f "${QTENV_OSG_LIB}" ]]; then
    QTV_LINKS="$(ldd_capture "${QTENV_OSG_LIB}" 'osgEarth|osgDB|osgViewer|OpenThreads|osg\.so|osgUtil')"
    if printf "%s\n" "${QTV_LINKS}" | rg -q "${OPENSCENEGRAPH_PREFIX}|${ACTIVE_OSGEARTH_PREFIX}"; then
        record_check "liboppqtenv-osg runtime links" "PASS" "linked to local OSG/osgEarth prefixes"
    else
        record_check "liboppqtenv-osg runtime links" "FAIL" "did not resolve local OSG/osgEarth prefixes"
    fi
    append "### liboppqtenv-osg.so"
    append ""
    append '```text'
    printf "%s\n" "${QTV_LINKS:-ldd output unavailable}" >> "${REPORT_FILE}"
    append '```'
    append ""
else
    record_check "liboppqtenv-osg runtime links" "FAIL" "missing activate_env.sh or ${QTENV_OSG_LIB}"
fi

if [[ -f "${PROJECT_ROOT}/activate_env.sh" && -f "${ESTNET_TEMPLATE_BIN}" ]]; then
    ESTNET_LINKS="$(ldd_capture "${ESTNET_TEMPLATE_BIN}" 'ESTNeT|INET|osgEarth|osgDB|osgViewer|OpenThreads|osg\.so|osgUtil')"
    if printf "%s\n" "${ESTNET_LINKS}" | rg -q "${ESTNET_DIR}|${INET_DIR}|${OPENSCENEGRAPH_PREFIX}|${ACTIVE_OSGEARTH_PREFIX}"; then
        record_check "estnet-template runtime links" "PASS" "linked to local ESTNeT/INET/OSG/osgEarth prefixes"
    else
        record_check "estnet-template runtime links" "FAIL" "did not resolve expected local libraries"
    fi
    append "### estnet-template binary"
    append ""
    append '```text'
    printf "%s\n" "${ESTNET_LINKS:-ldd output unavailable}" >> "${REPORT_FILE}"
    append '```'
    append ""
else
    record_check "estnet-template runtime links" "FAIL" "missing activate_env.sh or ${ESTNET_TEMPLATE_BIN}"
fi

append "## Summary"
append ""
append "- pass: ${PASS_COUNT}"
append "- warn: ${WARN_COUNT}"
append "- fail: ${FAIL_COUNT}"
append ""
append "| Check | Status | Details |"
append "| --- | --- | --- |"
printf "%b" "${SUMMARY_ROWS}" >> "${REPORT_FILE}"

printf "Wrote verification report: %s\n" "${REPORT_FILE}"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
exit 0
