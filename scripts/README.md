# Maintenance scripts

- `validate_spatial.sh` — package tests, contract tests, Python tests and unsigned app builds.
- `pull_diag.py` — copies the selected app's local Diagnostics directory from a connected device.
- `read_diag.py` / `summarize_session.py` — inspect DIAG exports without uploading data.
- `test_*.py` — reader, summary and source-structure regression tests.

Scripts are intentionally offline except for the device copy operation requested by the caller. They must not infer sensor truth from missing records.

## 开发信息采集

`read_dev_capture.py <dev-capture目录>` 验证配对索引、深度/DA附件及校验和，不上传或解码视频。
配置、隐私与数据格式见 `docs/DEV_CAPTURE.md`。

## 代码统计

运行 `python3 scripts/code_inventory.py --write` 更新代码量与完整源码树。统计物理行和非空行，包含注释；不将二进制模型、构建目录和冻结实验副本重复计入。

## 路线离线回放

先用 `read_dev_capture.py` 校验本地录制。回放只重新运行规划，地面分析与原始深度使用已保存的样本。
它不重建缺失的10Hz中间帧，也不模拟UI、语音或新轨迹下的传感器观测。

```sh
swift build --package-path Vendor/SpatialCore
swiftc -O -I Vendor/SpatialCore/.build/arm64-apple-macosx/debug/Modules   scripts/replay_routes.swift Vendor/SpatialCore/.build/arm64-apple-macosx/debug/SpatialCore.build/*.swift.o   -o /tmp/prts-replay
/tmp/prts-replay /absolute/path/dev-capture-* > /tmp/replay.jsonl
python3 scripts/compare_route_replays.py /tmp/before.jsonl /tmp/after.jsonl
```

比较要求相同顺序、epoch、frameID和timestamp；旧版可执行文件应在修改算法前保存。
脚本不操作设备、不上传数据。回放包含当前足迹/障碍一致性检查，独立真值误差仍需人工测量。

`replay_route_snapshots.swift` 读取逐行 `{result: AnalysisResult, options: PathOptions}`，
默认运行 verified_continuous_v1；历史实验比较须显式加 `--experimental-occupancy`。输入若来自compact-grid重建，必须注明缺少逐格原始样本计数，
不把结果标成完整传感器复现；保持真实时间戳，禁止给低帧率录像补造观测。
