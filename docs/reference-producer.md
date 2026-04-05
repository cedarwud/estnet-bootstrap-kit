# Reference Producer Runbook

這份文件描述 `feature/reference-producer` 目前建立的最小 producer/exporter 路線。它的目標不是把 viewer 綁回 OMNeT++ runtime，而是讓 bootstrap kit 可以獨立產出與驗證 frozen replay package。

## Goal

目前這條 control-layer 路線負責：

1. 建立 `18 sat walker + 2 endpoints` reference scenario
2. 以 release build 跑 headless producer simulation
3. 從 SQLite `.vec` 匯出 `EstnetReplayPackageV1`
4. 驗證 manifest / frame contract 與 native node identity mapping
5. 把 raw result、dataset、report 都留在 ignored workspace 路徑

## Main Entrypoint

建議直接使用：

```bash
./tools/run_reference_producer.sh
```

預設流程會做四件事：

1. `prepare`
   - 修復 moved-workspace git metadata
   - 修補 `omnetpp-5.5.1/Makefile.inc` / `configure.user` 內殘留的舊 workspace root
   - 強制重跑 Stage 70，生成最新 `activate_env.sh`
   - rebuild `ESTNeT` 與 `estnet-template` release target
2. `run`
   - 生成 reference scenario overlay
   - 跑 `ReferenceProducer` config
3. `export`
   - 從 SQLite vector DB 匯出 frozen replay package
4. `validate`
   - 驗證 manifest / frame contract
   - 驗證 `endpoint-a` / `endpoint-b` mapping

也可以分段執行：

```bash
./tools/run_reference_producer.sh prepare
./tools/run_reference_producer.sh run
./tools/run_reference_producer.sh export
./tools/run_reference_producer.sh validate
```

## Output Layout

每次執行都會建立一個新的 run 目錄：

```text
state/reference-producer/
├── latest -> runs/<run-id>
└── runs/
    └── <run-id>/
        ├── raw/
        ├── dataset/<dataset-id>/
        ├── reports/
        └── scenario/reference-producer.ini
```

重點輸出：

1. `raw/`
   - producer simulation 的 SQLite result DB
   - 目前 baseline 可能把 `vectorData` 寫進 `.sca`，不一定另外產生 `.vec`
2. `dataset/<dataset-id>/manifest.json`
3. `dataset/<dataset-id>/frames/frame-000001.json`
4. `reports/export-metadata.json`
5. `reports/validation-report.json`

這些都屬於 workspace-only output，不應提交。

## Frozen Contract Alignment

目前 exporter 直接對齊 viewer 已凍結的 `Phase 02` contract：

1. `manifest.json` 為唯一 entrypoint
2. frame 命名固定為六位數 zero-padded
3. `packageVersion = EstnetReplayPackageV1`
4. `frameSchemaVersion = EstnetLocalSceneFrameV1`
5. `sceneId = ntpu-local`
6. `coordinateFrame = ntpu-local-enu-v1`
7. `endpointIds = ["endpoint-a", "endpoint-b"]`
8. `satellites[]` 採完整 snapshot，不做 sparse delta

## Endpoint Mapping Validation Method

目前固定 native node identity 的方法不是靠 viewer runtime，也不是把 producer module path 混進 raw frame。流程如下：

1. scenario overlay 直接把兩個 ground node label 固定成：
   - `endpoint-a`
   - `endpoint-b`
2. validator 先讀 control-layer 生成的 `scenario/reference-producer.ini`：
   - `*.cg[*].label`
   - `*.cg[*].networkHost.mobility.lat`
   - `*.cg[*].networkHost.mobility.lon`
   - `*.cg[*].networkHost.mobility.alt`
3. validator 再用 result DB 確認同一個 run 內確實有：
   - `SpaceTerrestrialNetwork.cg[0].networkHost.mobility`
   - `SpaceTerrestrialNetwork.cg[1].networkHost.mobility`
   這兩個 native ground modules 的 recorded mobility vectors
4. validator 以 frozen `ntpu-local-enu-v1` anchor
   - latitude `24.9441667`
   - longitude `121.3713889`
   - altitude `50m`
   做 WGS84 geodetic -> local ENU 投影
5. validator 再把投影結果和 viewer endpoint registry 位置比較：
   - `endpoint-a` -> `[0.0, 0.0, 1.5]`
   - `endpoint-b` -> `[185.0, -52.0, 1.5]`

只要兩個 endpoint 都在 tolerance 內，mapping 就算固定完成。

## Workspace-Only Governance

這條線有兩類 workspace-only 修補，必須和 delivery repo 差異切開看：

1. moved worktree metadata repair
   - 由 `scripts/common.sh` 的 `repair_worktree_metadata()` 處理
2. moved workspace root repair
   - `run_reference_producer.sh` 會修補 `omnetpp-5.5.1/Makefile.inc` 與 `configure.user` 內殘留的舊 root path

這些修補的治理原則是：

1. 只改 ignored workspace surface
2. 不把 vendor tree 直接當成交付內容
3. 長期需要保留的行為，優先沉澱回 `tools/`、`scripts/` 或 `docs/`

目前這兩類修補都不是 `scripts/patches/*.patch`，因為它們處理的是本機生成或搬移後失效的 workspace 狀態，不是應提交的 vendor diff。

## Validation Outcome Interpretation

`validation-report.json` 目前會給出：

1. `packageValid`
2. `mappingValid`
3. `goldenDatasetReady`
4. `blockers[]`

若卡住，請用下列分類回報：

1. `scenario/config`
   - ground node label、endpoint geodetic placement、satellite count 或 TLE target 不符合預期
2. `exporter hook`
   - manifest / frame layout、frame sequence、satellite snapshot 或 JSON payload 有誤
3. `contract ambiguity`
   - viewer frozen contract 與 producer-side truth 邊界本身不清楚
4. `framework-level blocker`
   - OMNeT++ / INET / ESTNeT runtime 或 build 層卡住，還沒到 export contract

## Direct Python Entrypoints

若只想局部重跑 export 或 validate，可直接呼叫：

```bash
python3 ./tools/reference_producer.py export \
  --vector-db <path/to/ReferenceProducer-0.vec> \
  --tle-file <path/to/walker_o6_s3_i45_h698.tle> \
  --output-dir <dataset-dir> \
  --metadata-out <report-path> \
  --dataset-id ntpu-2-endpoints-via-leo-18sat-walker-v1
```

```bash
python3 ./tools/reference_producer.py validate \
  --dataset-dir <dataset-dir> \
  --vector-db <path/to/ReferenceProducer-0.vec> \
  --report-out <validation-report-path>
```
