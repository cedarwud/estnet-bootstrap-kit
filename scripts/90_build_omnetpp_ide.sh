#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

init_stage "90" "build_omnetpp_ide"
trap 'handle_unexpected_error $? ${LINENO} "${BASH_COMMAND}"' ERR

if stage_should_skip; then
    exit 0
fi

stage_begin_work

need_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        stage_mark_failure "Required command '${cmd}' is missing. Install package '${pkg}' and rerun Stage 90."
    fi
}

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

need_stage_success "40" "Stage 40 (OMNeT++ build)"
need_stage_success "70" "Stage 70 (activation script)"

need_command "mvn" "maven"
need_command "swig" "swig"
need_command "perl" "perl"
need_command "python3" "python3"
need_command "cp" "coreutils"
need_command "ln" "coreutils"
need_command "make" "make"
need_command "find" "findutils"

if [[ ! -d "${OMNETPP_DIR}/.git" ]]; then
    stage_mark_failure "OMNeT++ source tree is missing at ${OMNETPP_DIR}. Run Stage 10 first."
fi
if [[ "$(git -C "${OMNETPP_DIR}" rev-parse HEAD)" != "${OMNETPP_COMMIT}" ]]; then
    stage_mark_failure "OMNeT++ source tree at ${OMNETPP_DIR} is not pinned to ${OMNETPP_COMMIT}. Re-run Stage 10."
fi

export PATH="${OMNETPP_DIR}/bin:${PATH}"

java_version_string="$(java -version 2>&1 | sed -n '1s/.*version \"\\([^\"]*\\)\".*/\\1/p' | head -n1)"
java_major_version="$(printf '%s\n' "${java_version_string}" | awk -F. '{ if ($1 == "1") print $2; else print $1 }')"
append_summary "java.version=${java_version_string:-unknown}"
append_summary "java.major=${java_major_version:-unknown}"

select_java11_home() {
    local candidate=""
    local -a candidates=(
        "${JAVA11_HOME:-}"
        "/usr/lib/jvm/java-11-openjdk-amd64"
        "/usr/lib/jvm/java-11-openjdk"
        "/usr/lib/jvm/temurin-11-jdk-amd64"
        "/usr/lib/jvm/temurin-11-jdk"
    )

    for candidate in "${candidates[@]}"; do
        [[ -n "${candidate}" ]] || continue
        if [[ -x "${candidate}/bin/java" ]] && [[ -x "${candidate}/bin/javac" ]]; then
            printf "%s\n" "${candidate}"
            return 0
        fi
    done

    return 1
}

configure_stage90_java_runtime() {
    local java11_home=""

    if [[ -n "${java_major_version}" ]] && [[ "${java_major_version}" =~ ^[0-9]+$ ]] && (( java_major_version >= 14 )); then
        java11_home="$(select_java11_home || true)"
        if [[ -z "${java11_home}" ]]; then
            stage_mark_failure "Stage 90 detected Java ${java_version_string}, but Tycho/Eclipse 2019-03 packaging needs a Java 11 runtime with unpack200 support. Install openjdk-11-jdk and rerun Stage 90."
        fi

        export JAVA_HOME="${java11_home}"
        export PATH="${JAVA_HOME}/bin:${PATH}"
        append_summary "java.stage90_override=${JAVA_HOME}"
        log INFO "Stage 90 overriding JAVA_HOME to ${JAVA_HOME} for Tycho compatibility"
    else
        append_summary "java.stage90_override=none"
    fi
}

swig_version_string="$(swig -version 2>/dev/null | sed -n 's/^SWIG Version //p' | head -n1)"
swig_major_version="$(printf '%s\n' "${swig_version_string}" | awk -F. '{print $1}')"
swig_minor_version="$(printf '%s\n' "${swig_version_string}" | awk -F. '{print $2}')"
append_summary "swig.version=${swig_version_string:-unknown}"
append_summary "swig.major=${swig_major_version:-unknown}"
append_summary "swig.minor=${swig_minor_version:-unknown}"

patch_swig4_scave_plove() {
    local target_file="${OMNETPP_DIR}/ui/org.omnetpp.ide.nativelibs/scave-plove.i"
    local marker='specialize_std_map_on_both(std::string,,,,std::string,,,);'
    local replacement='   // SWIG 4.x: specialize_std_map_on_both is deprecated and may fail to parse on newer distros.'

    if [[ ! -f "${target_file}" ]]; then
        stage_mark_failure "Expected SWIG interface file is missing: ${target_file}"
    fi

    if grep -Fq "${replacement}" "${target_file}"; then
        append_summary "swig_patch.scave_plove=already_applied"
        return 0
    fi

    if ! grep -Fq "${marker}" "${target_file}"; then
        append_summary "swig_patch.scave_plove=marker_missing"
        stage_mark_failure "Could not find expected deprecated SWIG std::map specialization marker in ${target_file}"
    fi

    python3 - "${target_file}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = "   specialize_std_map_on_both(std::string,,,,std::string,,,);\n"
new = "   // SWIG 4.x: specialize_std_map_on_both is deprecated and may fail to parse on newer distros.\n"
text = path.read_text(encoding="utf-8")
if old not in text:
    raise SystemExit("expected_deprecated_macro_not_found")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

    append_summary "swig_patch.scave_plove=applied"
}

patch_swig4_scave_entryvector() {
    local target_file="${OMNETPP_DIR}/ui/org.omnetpp.ide.nativelibs/scave.i"

    if [[ ! -f "${target_file}" ]]; then
        stage_mark_failure "Expected SWIG interface file is missing: ${target_file}"
    fi

    python3 - "${target_file}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
modified = False
old = (
    "namespace omnetpp { namespace scave {\n\n"
    "%template(EntryVector) ::std::vector<omnetpp::scave::OutputVectorEntry>;\n\n"
    "%ignore IndexedVectorFileWriterNode;"
)
wrong = (
    "namespace omnetpp { namespace scave {\n\n"
    "namespace std {\n"
    "%template(EntryVector) vector<omnetpp::scave::OutputVectorEntry>;\n"
    "}\n\n"
    "%ignore IndexedVectorFileWriterNode;"
)
new = (
    "namespace std {\n"
    "%template(EntryVector) ::std::vector<omnetpp::scave::OutputVectorEntry>;\n"
    "}\n\n"
    "namespace omnetpp { namespace scave {\n\n"
    "%ignore IndexedVectorFileWriterNode;"
)

if new in text:
    print("already_applied")
elif old in text:
    text = text.replace(old, new, 1)
    modified = True
elif wrong in text:
    text = text.replace(wrong, new, 1)
    modified = True
else:
    raise SystemExit("expected_entryvector_block_not_found")

if modified:
    path.write_text(text, encoding="utf-8")
PY
    append_summary "swig_patch.scave_entryvector=checked"
}

patch_swig4_eventlog_intintmap() {
    local target_file="${OMNETPP_DIR}/ui/org.omnetpp.ide.nativelibs/eventlog.i"

    if [[ ! -f "${target_file}" ]]; then
        stage_mark_failure "Expected SWIG interface file is missing: ${target_file}"
    fi

    python3 - "${target_file}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "   specialize_std_map_on_both(int,,,,int,,,);\n"
new = "   // SWIG 4.x: specialize_std_map_on_both is deprecated and may fail to parse on newer distros.\n"

if new in text:
    print("already_applied")
elif old in text:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
else:
    raise SystemExit("expected_eventlog_intintmap_macro_not_found")
PY

    append_summary "swig_patch.eventlog_intintmap=checked"
}

if [[ -n "${swig_major_version}" ]] && [[ "${swig_major_version}" =~ ^[0-9]+$ ]] && (( swig_major_version >= 4 )); then
    set_checkpoint "swig_compat" "patching deprecated SWIG std::map macro for SWIG 4.x"
    patch_swig4_scave_plove
    patch_swig4_scave_entryvector
    patch_swig4_eventlog_intintmap
fi

configure_stage90_java_runtime

IDE_STAGE_DIR="${OMNETPP_IDE_BUILD_BASE}/${RUN_TS}"
IDE_WORK_UI_DIR="${IDE_STAGE_DIR}/ui"
IDE_PRODUCT_DIR="${IDE_WORK_UI_DIR}/releng/org.omnetpp.ide.product/target/products/org.omnetpp.ide.product/linux/gtk/x86_64"
IDE_LINK_PATH="${OMNETPP_DIR}/ide"

append_summary "ide_stage_dir=${IDE_STAGE_DIR}"
append_summary "ide_work_ui_dir=${IDE_WORK_UI_DIR}"
append_summary "ide_product_dir=${IDE_PRODUCT_DIR}"
append_summary "ide_link_path=${IDE_LINK_PATH}"
append_summary "ide_repo.main=${OMNETPP_IDE_MAIN_REPO_URL}"
append_summary "ide_repo.update=${OMNETPP_IDE_UPDATE_REPO_URL}"
append_summary "ide_repo.cdt=${OMNETPP_IDE_CDT_REPO_URL}"
append_summary "tycho.p2_mirrors=false"

set_checkpoint "ui_libs" "building OMNeT++ IDE native libraries"
(
    cd "${OMNETPP_DIR}"
    make MODE=release SWIG=swig JNILIBS_IF_POSSIBLE=jnilibs ui
)

if [[ ! -f "${OMNETPP_DIR}/ui/org.omnetpp.ide.nativelibs.linux.x86_64/libopplibs.so" ]]; then
    stage_mark_failure "UI native library build completed but libopplibs.so was not produced."
fi

append_summary "artifact.native_linux_lib=${OMNETPP_DIR}/ui/org.omnetpp.ide.nativelibs.linux.x86_64/libopplibs.so"

set_checkpoint "workspace_copy" "creating isolated UI packaging workspace"
mkdir -p "${IDE_STAGE_DIR}"
cp -a "${OMNETPP_DIR}/ui" "${IDE_WORK_UI_DIR}"
touch "${IDE_WORK_UI_DIR}/org.omnetpp.ide.nativelibs.win32.x86_64/opplibs.dll"
touch "${IDE_WORK_UI_DIR}/org.omnetpp.ide.nativelibs.macosx/libopplibs.jnilib"

set_checkpoint "workspace_sanitize" "removing unavailable OMNEST/commercial modules from isolated reactor"
python3 - "${IDE_WORK_UI_DIR}" <<'PY'
import pathlib
import sys

ui_dir = pathlib.Path(sys.argv[1])

def remove_module(pom_path: pathlib.Path, module_name: str) -> bool:
    original = pom_path.read_text(encoding="utf-8")
    needle = f"    <module>{module_name}</module>\n"
    if needle not in original:
        return False
    pom_path.write_text(original.replace(needle, ""), encoding="utf-8")
    return True

removed = []
if remove_module(ui_dir / "pom.xml", "org.omnetpp.main.omnest"):
    removed.append("ui/pom.xml:org.omnetpp.main.omnest")
if remove_module(ui_dir / "features" / "pom.xml", "org.omnetpp.ide.commercial"):
    removed.append("ui/features/pom.xml:org.omnetpp.ide.commercial")

if removed:
    print("removed=" + ",".join(removed))
else:
    print("removed=none")

patched = []

def patch_compat_methods(relative_path: str, marker: str, compat_methods: str, guard: str) -> None:
    path = ui_dir / relative_path
    if not path.exists():
        patched.append(f"missing:{relative_path}")
        return

    original = path.read_text(encoding="utf-8")
    if guard in original:
        patched.append(f"already:{relative_path}")
        return
    if marker not in original:
        patched.append(f"marker-missing:{relative_path}")
        return

    path.write_text(original.replace(marker, compat_methods + marker, 1), encoding="utf-8")
    patched.append(f"{relative_path}:compat")

patch_compat_methods(
    "org.omnetpp.ide.nativelibs/src/org/omnetpp/scave/engine/StringMap.java",
    "  public String remove(java.lang.Object key) {\n",
    (
        "  // SWIG 4 generates java.util.Map-style put(); older OMNeT++ UI code still calls set().\n"
        "  public void set(String key, String value) {\n"
        "    put(key, value);\n"
        "  }\n\n"
        "  public boolean has_key(String key) {\n"
        "    return containsKey(key);\n"
        "  }\n\n"
        "  public void del(String key) {\n"
        "    remove(key);\n"
        "  }\n\n"
    ),
    "public void set(String key, String value)",
)

patch_compat_methods(
    "org.omnetpp.ide.nativelibs/src/org/omnetpp/eventlog/engine/IntIntMap.java",
    "  public Integer remove(java.lang.Object key) {\n",
    (
        "  // SWIG 4 generates java.util.Map-style put(); older OMNeT++ UI code still calls set().\n"
        "  public void set(int key, int value) {\n"
        "    put(key, value);\n"
        "  }\n\n"
        "  public void set(Integer key, Integer value) {\n"
        "    put(key, value);\n"
        "  }\n\n"
        "  public boolean has_key(int key) {\n"
        "    return containsKey(key);\n"
        "  }\n\n"
        "  public boolean has_key(Integer key) {\n"
        "    return containsKey(key);\n"
        "  }\n\n"
        "  public void del(int key) {\n"
        "    remove(key);\n"
        "  }\n\n"
        "  public void del(Integer key) {\n"
        "    remove(key);\n"
        "  }\n\n"
    ),
    "public void set(int key, int value)",
)

startup_java = ui_dir / "org.omnetpp.main" / "src" / "org" / "omnetpp" / "ide" / "OmnetppStartup.java"
startup_original = startup_java.read_text(encoding="utf-8")
startup_marker = "                                openInitialPages(dialog.isImportSamplesRequested());\n"
startup_replacement = (
    "                                // On WSL and minimal Linux installs, SWT's internal Browser widget may be unavailable.\n"
    "                                // Skip auto-opening browser-backed welcome/documentation pages during first startup.\n"
    "                                // Users can still open documentation later after installing WebKitGTK.\n"
    "                                // openInitialPages(dialog.isImportSamplesRequested());\n"
)
if startup_marker in startup_original and startup_replacement not in startup_original:
    startup_java.write_text(startup_original.replace(startup_marker, startup_replacement, 1), encoding="utf-8")
    patched.append("org.omnetpp.main/src/org/omnetpp/ide/OmnetppStartup.java:skip_initial_browser_pages")
elif startup_replacement in startup_original:
    patched.append("already:org.omnetpp.main/src/org/omnetpp/ide/OmnetppStartup.java")
else:
    patched.append("marker-missing:org.omnetpp.main/src/org/omnetpp/ide/OmnetppStartup.java")

print("patched=" + ",".join(patched))
PY

set_checkpoint "tycho_build" "building OMNeT++ IDE product with Maven/Tycho"
(
    cd "${IDE_WORK_UI_DIR}"
    mvn clean verify \
        -Dwhat=omnetpp \
        -DforceContextQualifier="${RUN_TS}" \
        -Declipse.p2.mirrors=false \
        -Drepo.url="${OMNETPP_IDE_MAIN_REPO_URL}" \
        -Dupdate-repo.url="${OMNETPP_IDE_UPDATE_REPO_URL}" \
        -Dcdt-repo.url="${OMNETPP_IDE_CDT_REPO_URL}"
)

if [[ ! -d "${IDE_PRODUCT_DIR}" ]]; then
    stage_mark_failure "Tycho build completed but expected Linux IDE product directory is missing: ${IDE_PRODUCT_DIR}"
fi
if [[ ! -f "${IDE_PRODUCT_DIR}/omnetpp" ]]; then
    stage_mark_failure "Tycho build completed but Linux IDE launcher was not found at ${IDE_PRODUCT_DIR}/omnetpp"
fi
if [[ ! -d "${IDE_PRODUCT_DIR}/configuration" ]]; then
    stage_mark_failure "Tycho build completed but configuration directory is missing at ${IDE_PRODUCT_DIR}/configuration"
fi

append_summary "artifact.ide_launcher=${IDE_PRODUCT_DIR}/omnetpp"
append_summary "artifact.ide_configuration=${IDE_PRODUCT_DIR}/configuration"

set_checkpoint "install_link" "linking built IDE payload into OMNeT++ tree"
if [[ -e "${IDE_LINK_PATH}" ]] && [[ ! -L "${IDE_LINK_PATH}" ]]; then
    stage_mark_failure "Refusing to replace existing non-symlink IDE path: ${IDE_LINK_PATH}"
fi
IDE_LINK_TARGET_REL="$(python3 - "${OMNETPP_DIR}" "${IDE_PRODUCT_DIR}" <<'PY'
import os
import sys

omnetpp_dir = sys.argv[1]
ide_product_dir = sys.argv[2]
print(os.path.relpath(ide_product_dir, omnetpp_dir))
PY
)"
append_summary "ide_link_target_rel=${IDE_LINK_TARGET_REL}"
ln -sfn "${IDE_LINK_TARGET_REL}" "${IDE_LINK_PATH}"

if [[ ! -x "${IDE_LINK_PATH}/omnetpp" ]]; then
    stage_mark_failure "Linked IDE payload exists but launcher is not executable: ${IDE_LINK_PATH}/omnetpp"
fi

stage_mark_success "OMNeT++ IDE payload built and linked at ${IDE_LINK_PATH}."
