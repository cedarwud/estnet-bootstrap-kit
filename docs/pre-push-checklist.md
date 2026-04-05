# Pre-Push Checklist

這份 checklist 的目標是確保推上 GitHub 的只有 portable control layer，而不是本機 build/workspace 產物。

## 應該提交的內容

- `README.md`
- `.gitignore`
- `.env.local.example`
- `versions.env`
- `paths.env`
- `setup.sh`
- `run.sh`
- `detect_env.sh`
- `verify_versions.sh`
- `tools/`
- `scripts/`
- `docs/`

## 不應該提交的內容

- `.env.local`
- `.metadata/`
- `activate_env.sh`
- `build/`
- `sources/`
- `third_party/`
- `omnetpp-5.5.1/`
- `inet/`
- `estnet/`
- `estnet-template/`
- `logs/`
- `state/`

## 推送前檢查

1. 確認工作根目錄是 bootstrap kit 根目錄。
2. 確認 `.gitignore` 已忽略本機 workspace 與 build 產物。
3. 確認 `git status --short` 只出現控制層檔案。
4. 確認沒有把 OMNeT++ / INET / estnet / osgEarth build 產物加入版本控制。
5. 確認沒有把 `.metadata/` 或 `activate_env.sh` 加入版本控制。
6. 若剛做過本機測試，確認 `logs/`、`state/`、`build/` 仍然是 ignored。
7. 若需要對外說明使用方式，README 應以 `./setup.sh` 與 `./run.sh` 為主，而不是引用本機 build 後路徑。
8. 若剛跑過 `./tools/run_reference_producer.sh`，確認 `state/reference-producer/` 內的 raw result、dataset 與 reports 沒有被加入版本控制。
9. 若 reference producer 為了 moved workspace 修補了 `omnetpp-5.5.1/Makefile.inc` 或 `configure.user`，確認這些仍屬 ignored vendor tree，不要把修補後的 workspace 內容誤當成交付差異。

## 推送前建議命令

```bash
git status --short
git status --ignored --short
./detect_env.sh
```

## 可攜性原則

- bootstrap kit 是 fresh setup kit，不是 build artifact bundle
- 新環境應執行 `./setup.sh` 重建，而不是搬移舊的 workspace 產物
- `run.sh` 的預設行為應由環境偵測決定，必要時才用 `--software-gl` 或 `--native-gl` 覆蓋
- reference producer/exporter 的 dataset 與 raw result 只應存在於 `state/` 或其他 ignored workspace 路徑，不應直接納入 delivery repo
- moved-workspace repair 屬於 control-layer 治理；若要長期保留差異，優先沉澱成 `scripts/`、`tools/`、`docs/` 或 `scripts/patches/`，不要推送 vendor tree 本體
