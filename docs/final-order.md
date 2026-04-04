# Final Order

## Status

此文件已更新為目前在 `${PROJECT_ROOT}` 可重現的 build/debug baseline 執行順序。

## One-Time Prerequisites

`./setup.sh` 現在預設會先在 Ubuntu 環境中自動安裝必要系統套件。
若你想手動管理系統套件，再改用 `./setup.sh --skip-apt`。
若目前 session 無法互動輸入 sudo 密碼，先執行 `./setup.sh --print-apt-command`，手動安裝 prerequisite packages 後再執行 `./setup.sh --skip-apt`。

自動安裝清單如下：

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake pkg-config \
  python3 python-is-python3 \
  default-jre default-jdk \
  bison flex \
  maven swig \
  qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools libqt5opengl5-dev \
  <webkit-runtime-package> \
  xcursor-themes \
  libgl1-mesa-dev libglu1-mesa-dev \
  libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxmu-dev \
  libjpeg-dev libpng-dev libtiff-dev <freetype-dev-package> zlib1g-dev libfontconfig1-dev \
  libcurl4-openssl-dev libgdal-dev libgeos-dev libsqlite3-dev
```

補充：

- Ubuntu 20.04 / 22.04 的 WebKitGTK runtime package 通常是 `libwebkit2gtk-4.0-37`
- Ubuntu 24.04 通常改成 `libwebkit2gtk-4.1-0`
- Ubuntu 20.04 / 22.04 的 FreeType development package 通常是 `libfreetype6-dev`
- Ubuntu 24.04 可能改成 `libfreetype-dev`
- `./setup.sh` 會依 apt cache 自動選擇；若你手動安裝 prerequisite packages，請先用 `./setup.sh --print-apt-command` 取得當前環境正確的套件名稱
- `tools/run_stage.sh 90` 會在 `SWIG >= 4` 時自動套用 `scave-plove.i`、`scave.i`、`eventlog.i` 的相容修正，避免較新 Ubuntu/WSL 的 SWIG 解析失敗
- `tools/run_stage.sh 90` 若偵測到 `Java >= 14`，會優先使用本機已安裝的 `Java 11` 執行 Tycho；若系統沒有 Java 11，請先安裝 `openjdk-11-jdk`
- `tools/run_stage.sh 90` 也會停用 `p2` mirrors，避免舊 Eclipse repository 在某些環境下命中不穩定鏡像或 packed artifact 流程

## Primary Entrypoints

正常使用只需要兩個入口：

```bash
export PROJECT_ROOT=/path/to/project-root
cd "${PROJECT_ROOT}"

./setup.sh              # 預設等同 ready，一次性建置到可直接跑 omnetpp
./setup.sh --skip-apt   # 已自行安裝 prerequisite packages 時使用
./setup.sh --print-apt-command
./run.sh                # 之後反覆直接啟動 omnetpp

./setup.sh baseline     # 只做 baseline，不建 IDE payload
./setup.sh full         # 需要 Method B + IDE packaging 時才用
./setup.sh ide          # 只重跑 IDE packaging
```

補充：

- `setup.sh` / `run.sh` 是主要對外入口
- `tools/run_stage.sh`、`tools/run_all.sh`、`scripts/*.sh` 保留給 debug、局部重跑、問題定位，不是日常主入口
- `./detect_env.sh` 可單獨列出目前判定到的環境、版本、virtualization 與預設 run/setup 策略
- 在 native Linux / VMware / VirtualBox 的 Wayland session 下，`./run.sh` 會自動加上 `QT_QPA_PLATFORM=xcb`，減少 Qt/Wayland 警告
- `omnetpp-5.5.1/configure`、`omnetpp-5.5.1/setenv`、`inet/setenv` 屬於 setup 後的 upstream 腳本，不是 bootstrap kit 的主要對外入口

## Full Validation Order

```bash
export PROJECT_ROOT=/path/to/project-root
cd "${PROJECT_ROOT}"
./tools/run_stage.sh 00
./tools/run_stage.sh 10
./tools/run_stage.sh 20
./tools/run_stage.sh 30
./tools/run_stage.sh 31
./tools/run_stage.sh 40
./tools/run_stage.sh 50
./tools/run_stage.sh 60
./tools/run_stage.sh 70
./tools/run_stage.sh 80
./tools/run_stage.sh 90
```

## Preferred Downstream Baseline

若目標是後續繼續用 OMNeT++ / INET / estnet，而不是再次驗證兩條 osgEarth 路線，建議以 Method A 作為主路徑：

```bash
export PROJECT_ROOT=/path/to/project-root
cd "${PROJECT_ROOT}"
./tools/run_stage.sh 10
./tools/run_stage.sh 20
./tools/run_stage.sh 30
./tools/run_stage.sh 40
./tools/run_stage.sh 50
./tools/run_stage.sh 60
./tools/run_stage.sh 70
./tools/run_stage.sh 80
```

Method B (`./tools/run_stage.sh 31`) 保留作為 osgEarth 2.7 的第二條 corroboration 路線。

若目標包含 `omnetpp` IDE launcher 本身，請再加：

```bash
export PROJECT_ROOT=/path/to/project-root
cd "${PROJECT_ROOT}"
./tools/run_stage.sh 90
```

## Activation

原始流程仍可用：

```bash
cd "${PROJECT_ROOT}/omnetpp-5.5.1"
source setenv
cd "${PROJECT_ROOT}/inet"
source setenv
command -v omnetpp
```

統一流程也已可用：

```bash
cd "${PROJECT_ROOT}"
source "${PROJECT_ROOT}/activate_env.sh"
command -v omnetpp
```

WSL runtime 補充：

- `./run.sh` 現在會自動偵測 WSL，並在 WSL 下預設套用 software GL workaround
- 若要手動覆蓋，可用 `./run.sh --software-gl` 或 `./run.sh --native-gl`
- 這會讓 IDE 與其啟動的 simulation process 繼承 llvmpipe/software GL 設定
- 目前已驗證 `moon_1024x512.jpg` 缺檔問題已修正，相關 data asset 會由 Stage 30/31 安裝，Stage 70 會自動設定 `OSG_FILE_PATH`
- 若仍有 OpenGL framebuffer 問題，請將其歸類為 WSL runtime limitation，而不是 build failure

補充：

- 目前這套 source-tree build 可保證 `omnetpp` 命令、`opp_run`、`Qtenv/OSG` 相關 library 與 INET runner 都已建好
- Stage 90 已額外把 Eclipse-based IDE payload build 並掛到 `omnetpp-5.5.1/ide`
- `source "${PROJECT_ROOT}/activate_env.sh" && omnetpp` 已不再回報 `The OMNeT++ IDE is not installed!`
- 以前景直接 probe `timeout 15s "${PROJECT_ROOT}/omnetpp-5.5.1/ide/omnetpp" -nosplash -data /tmp/omnetpp-ide-smoke-workspace`，在 unsandboxed WSL probe 下可持續存活到 timeout；表示 launcher/IDE binary 可啟動，不是立即崩潰
- 觀察到一則 `Gtk-WARNING` 尺寸配置警告，但目前只歸類為 runtime warning

## Verified Local Patches / Workarounds

- `scripts/patches/osgearth-2.7-osg36-gcc9-compat.patch`
- `scripts/patches/omnetpp-5.5.1-local-osg-cflags.patch`
- `scripts/patches/inet-4.2-local-osg-link.patch`
- `third_party/install/toolchain-shims/bin/python -> /usr/bin/python3`

## VMware Runtime Next Step

把目前 workspace 複製到 VMware 或在 VMware 上依同一順序重跑 stage。到 VMware 後再做真正的圖形 runtime 驗證：

1. `source "${PROJECT_ROOT}/activate_env.sh"`
2. 執行 `omnetpp`
3. 先驗證 OMNeT++ 內建 OSG 範例，例如 `samples/osg-earth`
4. 再驗證 INET 的 OSG/osgEarth 視覺化場景
5. 最後匯入並執行 `estnet-template` 的 `simulations/omnetpp.ini`

若 VMware 環境出現 OpenGL/GLSL profile 問題，再單獨歸類為 runtime/platform 問題，不要回頭誤判成目前這套 build 流程失敗。
