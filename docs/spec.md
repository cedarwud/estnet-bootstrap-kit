# Build Spec

## Goal

在 `${PROJECT_ROOT}` 建立一套可重現、可分階段重跑、可保留 log 與 state 的 build/debug baseline，用來驗證下列組合。這套流程最初以 `WSL2 Ubuntu 20.04` 為 build/debug baseline 建立，現在也支援在 Ubuntu `20.04 / 22.04 / 24.04` 的 `WSL / VMware / VirtualBox / native Linux` 環境重跑 `setup.sh` 與 `run.sh`：

- OMNeT++ 5.5.1
- INET 4.2
- estnet
- estnet-template
- OpenSceneGraph
- osgEarth 2.7

此 baseline 只負責 build/debug 與錯誤收斂，不把 WSL 視為最終 OSG/osgEarth 圖形驗證平台。最終 GUI/runtime 驗證預計搬到 VMware 或其他較穩定的 Linux GUI 環境。

## Primary Entrypoints

對外主要入口只有：

- `./setup.sh`
- `./run.sh`

補充入口：

- `./detect_env.sh`
  - 只輸出目前環境判斷結果
- `./verify_versions.sh`
  - 驗證 source pin、installed headers、configure.user 與 runtime link
- `./tools/run_all.sh`
  - 一次執行多個 stage
- `./tools/run_stage.sh`
  - 只執行單一 stage

`tools/` 與 `scripts/00..90.sh` 是進階/debug 骨架，不應該當成日常主入口。

## Environment Model

這套 bootstrap kit 會在 `setup` 與 `run` 開始時自動偵測目前環境。  
目前會辨識：

- Linux 發行版
- `VERSION_ID`
- codename
- virtualization 類型
- 是否為 WSL

目前真正用於自動決策的行為：

- `setup.sh`
  - 在 Ubuntu/WSL 內自動安裝 prerequisite packages
  - 若處於 non-interactive session 而無法輸入 sudo 密碼，應先改用 `./setup.sh --print-apt-command`，待使用者手動安裝 prerequisite packages 後再執行 `./setup.sh --skip-apt`
- `run.sh`
  - 在 `WSL` 下預設使用 software GL
  - 在非 `WSL` 環境下預設使用 native GL
  - 在 native Linux / VMware / VirtualBox 的 Wayland session 下，會額外自動套用 `QT_QPA_PLATFORM=xcb`

Ubuntu 版本資訊目前會用於套件名稱選擇與少數相容性 workaround，例如 WebKitGTK、FreeType、Stage 90 的 Java/SWIG/Tycho；runtime 啟動策略則優先依環境與 session 類型決定。

## Required Configuration

`configure.user` 必須最終驗證下列設定：

- `PREFER_CLANG=no`
- `PREFER_SQLITE_RESULT_FILES=yes`
- `WITH_OSG=yes`
- `WITH_OSGEARTH=yes`

## Execution Principles

- 先探索 workspace，再動手建立流程。
- 不做單一從頭跑到尾的大腳本，必須拆成獨立 stage。
- 每個 stage 都要有：
- 獨立腳本
- 獨立 log
- 成功條件
- 失敗摘要
- checkpoint / state file
- 某一 stage 失敗時，先停在該 stage，分析 root cause，修正後只重跑該 stage。
- 優先使用專案內 prefix，例如 `third_party/install/...`。
- 不覆蓋或回退使用者既有修改。
- 任何 GUI/WSLg/OpenGL 限制都記為 runtime limitation，不誤判成 build failure。
- bootstrap kit 只攜帶控制層，不把既有 build artifacts 當成可搬移資產。

## Repository Layout

- `versions.env`
  - 版本與 ref 集中管理
- `paths.env`
  - 目錄與 install prefix 集中管理
- `scripts/common.sh`
  - stage 共用 helper，負責 log、state、checkpoint、環境偵測
- `scripts/[00-90]_*.sh`
  - 可獨立重跑的各 stage 腳本
- `tools/run_stage.sh`
  - stage runner，支援 `--force`
- `tools/run_all.sh`
  - 多個 stage 的批次 runner
- `tools/start_omnetpp.sh`
  - `run.sh` 實際呼叫的內部 launcher
- `setup.sh`
  - 新環境主要入口
- `run.sh`
  - 日常啟動 OMNeT++ IDE 的主要入口
- `detect_env.sh`
  - 顯示目前環境判斷結果
- `verify_versions.sh`
  - 版本與 runtime link 驗證入口
- `logs/`
  - 每次 stage 執行都寫入 timestamped log，並維護 latest symlink
- `state/`
  - 每個 stage 的 `.state`、`.summary`、`.checkpoint`
- `docs/`
  - 規格、階段定義與最終執行順序文件

## Version Policy

已完成實際 pin：

- OMNeT++ `omnetpp-5.5.1` at `f0a213dad1597c6ff9934b6320da828c99531762`
- INET `v4.2.0` at `cb6c37b3dcb76b0cecf584e87e777d965bf1ca6c`
- OpenSceneGraph `OpenSceneGraph-3.6.5` at `a827840baf0786d72e11ac16d5338a4ee25779db`
- osgEarth `osgearth-2.7` at `25ce0e1b7a47311d1c19f5e76f208d7cd4388f94`
- estnet `v1.0` at `2355ffe3c396510a182debf7c2a57d6559df942b`
- estnet-template `v0.9` at `fb76667fb43a2935ecb4bccf00cf58e88e26c407`

補充：

- `osgearth-2.7` 這個 ref 的內部版本字串仍顯示 `2.6.0`
- 最終以 git tag / commit 判定版本

## osgEarth 2.7 Strategy

- 方法 A：沿用官方 build 文件的核心邏輯，但必須改寫成適合 `2.7` 的流程，不能直接套用 3.x 假設。
- 方法 B：沿用使用者提供參考文章的流程，再針對目前 baseline 做必要調整。
- 兩條方法都要記錄：
- 使用的 upstream ref
- 依賴版本
- build flags
- patch 與 workaround
- 結果差異

## Initial Success Criteria

- Stage framework 可建立 log/state/checkpoint。
- `00_env_check.sh` 能輸出工具鏈與缺少套件清單。
- `setup.sh` 與 `run.sh` 能自動偵測環境並採用合理預設。
- 後續 stage 能各自獨立重跑，不互相覆蓋狀態。

## Deferred Success Criteria

- OpenSceneGraph 已獨立 build 並安裝到局部 prefix。
- osgEarth 2.7 方法 A/B 已成功 build，且差異已記錄。
- OMNeT++ `./configure` summary 已實測 `WITH_OSG=yes` 與 `WITH_OSGEARTH=yes`。
- `make` 已完成。
- INET 4.2 已進入專案、命名為 `inet`、並通過 setenv 驗證與 release/debug build。
- estnet 與 estnet-template 已取得且版本已 pin。
- 統一環境腳本已支援：
- `cd omnetpp-5.5.1`
- `source setenv`
- `cd ../inet`
- `source setenv`
- `omnetpp`
