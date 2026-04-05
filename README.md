# estnet-bootstrap-kit

這個專案是 `estnet-bootstrap-kit`。它是一個可交付的 bootstrap/control layer，目的是讓新環境只靠這個 kit 就能：

- 執行 `./setup.sh` 從頭建出 baseline
- 執行 `./run.sh` 啟動 OMNeT++ IDE
- 保留 `tools/run_stage.sh` 與 `scripts/00..90.sh` 作為可重跑、可定位問題的 debug 骨架

補充：

- 文件中的專案名稱統一使用 `estnet-bootstrap-kit`

## Quick Start

```bash
export PROJECT_ROOT=/path/to/project-root
cd "${PROJECT_ROOT}"
./setup.sh
./run.sh
```

補充：

- `./setup.sh` 會先偵測環境，再在 Ubuntu/WSL 內自動執行 `sudo apt-get install`
- `./run.sh` 會先偵測環境，再自動決定預設 GL 模式與必要的 Qt backend workaround
- 在 native Linux / VMware / VirtualBox 的 Wayland session 下，`./run.sh` 會自動切 `QT_QPA_PLATFORM=xcb`，避開 Qt/Wayland 的 `requestActivate()` / `QSocketNotifier` 警告
- 若只想看目前環境判斷結果，可執行 `./detect_env.sh`
- 若目前 session 無法互動輸入 `sudo` 密碼，可先執行 `./setup.sh --print-apt-command`，手動安裝 prerequisite packages 後再執行 `./setup.sh --skip-apt`

## Script Reference

### Main Entrypoints

- `./setup.sh`
  - 新環境主要入口
  - 會先偵測環境，再安裝 prerequisite packages，最後執行預設 stage flow
  - 用法：
    - `./setup.sh`
    - `./setup.sh baseline`
    - `./setup.sh full`
    - `./setup.sh ide`
    - `./setup.sh --skip-apt`
    - `./setup.sh --print-apt-command`
    - `./setup.sh --force`

- `./run.sh`
  - 日常啟動 OMNeT++ IDE 的主要入口
  - 會依目前環境自動選擇預設 GL 模式與必要的 Qt backend workaround
  - 用法：
    - `./run.sh`
    - `./run.sh --software-gl`
    - `./run.sh --native-gl`

- `./verify_versions.sh`
  - 驗證目前 workspace 是否真的對應到：
    - OMNeT++ 5.5.1
    - INET 4.2
    - OpenSceneGraph 3.6.5
    - osgEarth 2.7
  - 會檢查 source pin、installed headers、`configure.user`、以及實際 runtime link
  - 每次執行都會覆寫：
    - `state/version-verification.md`
  - 用法：
    - `./verify_versions.sh`

- `./detect_env.sh`
  - 輸出目前偵測到的：
    - environment
    - distro
    - `VERSION_ID`
    - codename
    - virtualization
    - setup/run 預設策略
  - 用法：
    - `./detect_env.sh`

### Debug Entrypoints

- `./tools/run_all.sh`
  - 依 mode 一次執行多個 stage
  - 比 `setup.sh` 更偏 debug / 進階操作
  - 用法：
    - `./tools/run_all.sh ready`
    - `./tools/run_all.sh baseline`
    - `./tools/run_all.sh full`
    - `./tools/run_all.sh ide`
    - `./tools/run_all.sh ready --force`

- `./tools/run_stage.sh`
  - 只執行單一 stage
  - 用於局部重跑、問題定位、只修某一階段
  - 用法：
    - `./tools/run_stage.sh --list`
    - `./tools/run_stage.sh 40`
    - `./tools/run_stage.sh --force 50`

- `./tools/run_reference_producer.sh`
  - reference producer / exporter 的 control-layer 入口
  - 會修復 moved-workspace metadata、重新生成 `activate_env.sh`、build `ESTNeT`/`estnet-template` release target、跑 `18 sat walker + 2 endpoints` reference scenario，並匯出/驗證 frozen replay package contract
  - 預設輸出會放在：
    - `state/reference-producer/runs/<run-id>/raw/`
    - `state/reference-producer/runs/<run-id>/dataset/<dataset-id>/`
    - `state/reference-producer/runs/<run-id>/reports/`
  - exporter 會自動偵測 raw 目錄下真正承載 `vectorData` 的 SQLite result DB；在目前 baseline 下，這可能是 `.sca` 而不是獨立 `.vec`
  - 用法：
    - `./tools/run_reference_producer.sh`
    - `./tools/run_reference_producer.sh prepare`
    - `./tools/run_reference_producer.sh run`
    - `./tools/run_reference_producer.sh export`
    - `./tools/run_reference_producer.sh validate`
    - `./tools/run_reference_producer.sh --sim-time-limit 120s --frame-step 1s`

- `./tools/reference_producer.py`
  - `run_reference_producer.sh` 背後使用的 exporter / validator
  - 平常建議透過 shell wrapper 呼叫；若要局部重跑 export 或 contract validation，才直接使用
  - 用法：
    - `python3 ./tools/reference_producer.py export ...`
    - `python3 ./tools/reference_producer.py validate ...`

### Generated / Internal Scripts

- `./activate_env.sh`
  - 由 Stage 70 產生的統一環境腳本
  - 可手動 source
  - 用法：
    - `source ./activate_env.sh`

- `./tools/start_omnetpp.sh`
  - `run.sh` 內部實際呼叫的 launcher
  - 平常通常不需要直接呼叫

- `scripts/common.sh`
  - 共用函式庫
  - 不是獨立入口

- `scripts/00_env_check.sh` 到 `scripts/90_build_omnetpp_ide.sh`
  - 各 stage 的實作本體
  - 平常不要直接呼叫，建議經由 `./tools/run_stage.sh`

## Stage Reference

- `00`
  - 檢查 OS、WSL、compiler、cmake、git、java、python、make、Qt、OpenGL/GLX、WebKitGTK 等依賴

- `10`
  - 下載並 pin 所有 source

- `20`
  - build OpenSceneGraph 到 local prefix

- `30`
  - build osgEarth 2.7 Method A

- `31`
  - build osgEarth 2.7 Method B

- `40`
  - 修改 `configure.user`
  - 執行 `./configure`
  - build OMNeT++

- `50`
  - 準備並 build INET 4.2
  - 修正 INET IDE metadata

- `60`
  - clone/prepare estnet 與 estnet-template
  - 補 estnet-template 必要 runtime config

- `70`
  - 產生統一 `activate_env.sh`

- `80`
  - 做 activation / binary / library / runtime policy smoke test

- `90`
  - build 並掛接 OMNeT++ IDE payload

## Reference Producer

`main` 現在只保留 bootstrap/control-layer baseline。第一階段 reference producer surface 與後續 orbit export follow-on work 由 `feature/reference-producer` 承接；它的責任是把 `estnet-bootstrap-kit` 變成 reference producer proving ground，而不是把 viewer 綁回 producer runtime。

目前控制面已經補上：

- `scripts/70_activate_env.sh`
  - 生成的 `activate_env.sh` 現在會同時暴露 OMNeT++ / INET / `ESTNeT` / OSG / osgEarth runtime library 路徑
- `verify_versions.sh`
  - runtime link 檢查已改成讀真正的 `estnet-template` release binary
- `tools/run_reference_producer.sh`
  - 把 reference scenario proof、export 與 validation 收斂成可重跑路徑
- `tools/reference_producer.py`
  - 對 frozen replay package contract 做 export-side guardrail、endpoint mapping validation，以及最小 `activePath` truth/export

補充：

- 這條線的 generated replay dataset、raw `.vec`/`.sca` 與 validation report 都是 workspace-only output，不是交付 repo 內容
- 目前 golden replay dataset 的 frame 會帶最小：
  - `activePath.endpointIds`
  - `activePath.satelliteId`
- 這個 `activePath` 不是 viewer 假資料；它是用 producer 端 mobility truth 推導出「同時對兩個 endpoint 可見、且共同最小 elevation 最高」的單跳 relay satellite
- 目前 reference run 只模擬到 `60s`，而模板中的顯式 app traffic 從 `180s` 才開始，因此這一輪不能把 packet/throughput 當成可用 path truth
- 若 workspace 因搬移目錄導致 `omnetpp-5.5.1/Makefile.inc` 或 `configure.user` 殘留舊 root path，`run_reference_producer.sh` 會在本機 workspace 內自動修補；這是 control-layer 治理，不代表 vendor tree 變成交付內容
- 具體 runbook 與 patch/workspace 治理說明見 `docs/reference-producer.md`

## Environment Detection

`setup.sh` 與 `run.sh` 都會在一開始自動偵測環境。  
目前會辨識：

- Linux 發行版
- `VERSION_ID`
- codename
- virtualization 類型
- 是否為 WSL

目前的預設策略是：

- `WSL`
  - `run` 預設使用 software GL

- 非 `WSL`
  - `run` 預設使用 native GL
  - 若是 native Linux / VMware / VirtualBox 的 Wayland session，另會自動加上 `QT_QPA_PLATFORM=xcb`

這代表：

- 在 WSL2/WSLg，直接 `./run.sh` 就會自動套用 software GL workaround
- 在 VMware / VirtualBox / 原生 Ubuntu Desktop，直接 `./run.sh` 會先走 native GL

需要手動覆蓋時可用：

```bash
./run.sh --software-gl
./run.sh --native-gl
```

`--software-gl` 的意義：

- 強制使用 Mesa llvmpipe
- 避開 WSLg 的 D3D12/OpenGL 轉譯不穩定問題

這是 WSL baseline workaround，不取代 VMware 或其他穩定 Linux GUI 環境的最終圖形驗證。

## Setup Notes

`./setup.sh` 在 Ubuntu/WSL 會自動安裝 prerequisite packages。  
目前包含：

- build-essential / cmake / pkg-config
- python3 / python-is-python3
- default-jre / default-jdk
- bison / flex
- maven / swig
- Qt 開發套件
- 版本相依的 WebKitGTK runtime package
- `xcursor-themes`
- OpenGL / X11 開發套件
- 版本相依的 FreeType development package
- curl / gdal / geos / sqlite3 開發套件

補充：

- `libwebkit2gtk-4.0-37` 是 IDE 內建 Browser widget 的 runtime dependency
- 在 Ubuntu 20.04 / 22.04 常見套件名是 `libwebkit2gtk-4.0-37`
- 在 Ubuntu 24.04 常見套件名改為 `libwebkit2gtk-4.1-0`
- `setup.sh` 現在會依目前 apt 可用套件自動選擇，不再把 24.04 硬套成 `4.0-37`
- Ubuntu 20.04 / 22.04 常見 FreeType development package 是 `libfreetype6-dev`
- Ubuntu 24.04 常見 FreeType development package 可能改成 `libfreetype-dev`
- `setup.sh` 與 Stage 20 現在會依目前 apt 可用套件自動選擇，不再把 FreeType package 名稱寫死
- Stage 90 會在 `SWIG >= 4` 時自動套用 OMNeT++ 5.5.1 UI native libs 的相容修正，避開 `scave-plove.i` / `eventlog.i` 的 deprecated `specialize_std_map_on_both(...)` 巨集，以及 `scave.i` 的 `EntryVector` template scope 在較新 Ubuntu/WSL 上造成的語法錯誤
- Stage 90 若偵測到 `Java >= 14`，會優先切到本機已安裝的 `Java 11` 來執行 Tycho；若沒有 Java 11，會直接提示安裝 `openjdk-11-jdk`
- Stage 90 的 Maven/Tycho packaging 會加上 `-Declipse.p2.mirrors=false`，避免舊 Eclipse repository 被第三方 mirror 或 packed artifact 邏輯拖垮
- 它不是 simulation / OSG / osgEarth build 的核心依賴，而是 IDE 內建 Browser widget 的 optional runtime dependency；缺少時主要影響 welcome/documentation/browser 類頁面
- `xcursor-themes` 是 Eclipse/SWT 在 Linux/GTK 下建立 cursor 時的 runtime dependency；缺少時可能在 workspace chooser 就直接報 `SWTError: No more handles`
- `python-is-python3` 是為了兼容 OMNeT++ / INET 仍使用 `#!/usr/bin/env python` 的上游輔助腳本；只靠 shell alias 不可靠
- 若系統暫時沒有 `python` alias，Stage 50 會建立 project-local fallback：`third_party/install/toolchain-shims/bin/python -> python3`
- 若你已自行準備好系統套件，可用 `./setup.sh --skip-apt`
- 若你處在 non-interactive session，無法由 `setup.sh` 直接執行 `sudo apt-get`，可先用：

```bash
./setup.sh --print-apt-command
```

複製輸出的安裝命令到可輸入 sudo 密碼的 shell 中手動執行，之後再回來跑：

```bash
./setup.sh --skip-apt
```

## Upstream Scripts After Setup

以下腳本是 setup 後會出現的 upstream 腳本，不是 bootstrap kit 的主要對外入口：

- `omnetpp-5.5.1/configure`
  - OMNeT++ upstream configure script
  - 由 Stage 40 使用

- `omnetpp-5.5.1/setenv`
  - OMNeT++ upstream environment script
  - 可手動 source，但日常建議優先用 `source ./activate_env.sh`

- `inet/setenv`
  - INET upstream environment script
  - 可手動 source，但日常建議優先用 `source ./activate_env.sh`

## Portability Notes

這個 kit 預期用在新環境 fresh setup。  
不要把舊環境已經 build 過的下列目錄一起帶過來：

- `sources/`
- `build/`
- `third_party/`
- `omnetpp-5.5.1/`
- `inet/`
- `estnet/`
- `estnet-template/`
- `activate_env.sh`
- `logs/`
- `state/`

原因：

- `git worktree` metadata
- OMNeT++ / INET 產生的 makefiles
- configure 結果
- build artifact 的 RPATH

都可能包含環境相關路徑。這些是可重建產物，不應該被當成可攜資產。

真正需要帶走的只有：

- `versions.env`
- `paths.env`
- `setup.sh`
- `run.sh`
- `detect_env.sh`
- `verify_versions.sh`
- `tools/`
- `scripts/`
- `README.md`
- `.gitignore`
- `.env.local.example`
- `docs/spec.md`
- `docs/stages.md`
- `docs/final-order.md`
- `docs/pre-push-checklist.md`

推送到 GitHub 前，請先看：

- `docs/pre-push-checklist.md`

## Env Files

- `versions.env` 與 `paths.env`
  - 版本控制中的專案設定
  - 應提交到 Git

- `.env.local`
  - 本機覆寫檔
  - 預設不提交

- `.env.local.example`
  - 本機覆寫範本

如果照這個 kit 在新位置重新 `setup`，理論上不會重現「搬移已建好 workspace 後 worktree / link path 壞掉」的問題。
