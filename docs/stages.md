# Build Stages

## Primary Flow

日常主要入口：

- `./setup.sh`
- `./run.sh`

進階 / debug 入口：

- `./detect_env.sh`
- `./verify_versions.sh`
- `./tools/run_all.sh`
- `./tools/run_stage.sh`

`scripts/00..90.sh` 是 stage 實作本體，主要經由 `./tools/run_stage.sh` 觸發。

## Stage Contract

每個 stage 都遵守以下契約：

- 單獨腳本：`scripts/<stage>_*.sh`
- 單獨 log：`logs/<stage>_<name>_<timestamp>.log`
- state file：`state/<stage>.state`
- checkpoint file：`state/<stage>.checkpoint`
- summary file：`state/<stage>.summary`
- 成功後可跳過重跑；若需強制重跑，使用 `./tools/run_stage.sh --force <stage>`
- 失敗時停在該 stage，不自動往下執行

## Environment Awareness

這套流程在 `setup` 與 `run` 開始時都會自動偵測：

- Linux 發行版
- `VERSION_ID`
- codename
- virtualization 類型
- 是否為 WSL

目前真正影響預設行為的是：

- `setup.sh`
  - 在 Ubuntu/WSL 內自動安裝 prerequisite packages
  - 若目前 session 無法互動輸入 sudo 密碼，應先用 `./setup.sh --print-apt-command` 取得手動安裝命令，再以 `./setup.sh --skip-apt` 繼續 stage flow
- `run.sh`
  - 在 `WSL` 下預設使用 software GL
  - 在非 `WSL` 環境下預設使用 native GL
  - 在 native Linux / VMware / VirtualBox 的 Wayland session 下，會額外自動套用 `QT_QPA_PLATFORM=xcb`

Ubuntu 版本資訊目前會用於記錄、套件名稱選擇與相容性 workaround；runtime 啟動策略則優先依環境與 session 類型決定。

## Stage List

| Stage | Script | Purpose | Current Scope | Success Condition |
| --- | --- | --- | --- | --- |
| 00 | `scripts/00_env_check.sh` | 檢查環境、依賴與 WSL 限制 | 已驗證成功 | 產出環境摘要、缺少套件清單與 runtime limitation 記錄 |
| 10 | `scripts/10_fetch_sources.sh` | 下載或 clone 所有必要 source 並 pin 版本 | 已驗證成功 | 所有來源取得完成且 commit/tag 明確寫入紀錄 |
| 20 | `scripts/20_build_openscenegraph.sh` | 獨立 build OpenSceneGraph | 已驗證成功 | install prefix 內有 include/lib/bin，且版本與 flags 已記錄 |
| 30 | `scripts/30_build_osgearth_27_method_a.sh` | 依官方文件邏輯調整後 build osgEarth 2.7 | 已驗證成功 | 完成 configure/build/install，並記錄 2.7 專屬調整與 patch |
| 31 | `scripts/31_build_osgearth_27_method_b.sh` | 依參考文章邏輯調整後 build osgEarth 2.7 | 已驗證成功 | 完成 configure/build/install，並與 Method A 對照差異 |
| 40 | `scripts/40_build_omnetpp.sh` | 修改 `configure.user`、跑 `./configure` 與 `make` | 已驗證成功 | configure summary 顯示 `WITH_OSG=yes` 與 `WITH_OSGEARTH=yes`，並完成 `make` |
| 50 | `scripts/50_build_inet.sh` | 安裝 INET 4.2、改名為 `inet`、驗證 setenv | 已驗證成功 | `inet` 目錄可用、release/debug build 完成、`source setenv` 可通過 |
| 60 | `scripts/60_clone_estnet.sh` | clone estnet 與 estnet-template | 已驗證成功 | 兩個 repo 取得完成且 ref 已記錄 |
| 70 | `scripts/70_activate_env.sh` | 產生統一環境啟動腳本 | 已驗證成功 | 生成 `${PROJECT_ROOT}/activate_env.sh`，驗證可 source，並正確設定 OSG/osgEarth runtime path |
| 80 | `scripts/80_smoke_test.sh` | 最小 smoke test 與 WSL runtime 分類 | 已驗證成功 | setenv/source/path/binary/library 驗證完成；GUI 項目標記 skipped 或 runtime limitation with reason |
| 90 | `scripts/90_build_omnetpp_ide.sh` | build 開源版 OMNeT++ IDE payload 並掛回 `omnetpp-5.5.1/ide` | 已驗證成功 | Tycho product build 完成，`${PROJECT_ROOT}/omnetpp-5.5.1/ide/omnetpp` 與 `configuration/` 存在，launcher probe 不再回報 `IDE is not installed`；在 `SWIG >= 4` 時會自動修正 `scave-plove.i` / `eventlog.i` 的 deprecated `std::map` macro 與 `scave.i` 的 `EntryVector` template scope；若系統預設 Java 太新，會優先切到 Java 11，並停用 p2 mirrors |

## Current Execution Order

1. `00_env_check`
2. `10_fetch_sources`
3. `20_build_openscenegraph`
4. `30_build_osgearth_27_method_a`
5. `31_build_osgearth_27_method_b`
6. `40_build_omnetpp`
7. `50_build_inet`
8. `60_clone_estnet`
9. `70_activate_env`
10. `80_smoke_test`
11. `90_build_omnetpp_ide`

## Notes

- Stage 30 與 31 必須比較差異，並把差異寫回對應文件。
- Stage 40 之前不應假設 `WITH_OSGEARTH=yes` 已成立，必須以 configure summary 實測。
- Stage 80 若碰到 WSL GUI 問題，只能標成 runtime limitation 或 skipped，不得當成 build failure。
- Stage 90 是補 `omnetpp` Eclipse-based IDE payload 的獨立路線；它不改變前面 build/debug baseline 的成功與否，但若目標是實際執行 `omnetpp` launcher，就需要執行這一階段。
- `setup.sh` 預設等同 `ready` flow：`00 10 20 30 40 50 60 70 80 90`
- `run.sh` 會在啟動前依環境自動選擇 GL 策略；WSL 下預設 software GL
- `run.sh` 會在 native Linux / VMware / VirtualBox 的 Wayland session 下自動加上 `QT_QPA_PLATFORM=xcb`
