# 脚本

`scripts/` 里的工具都在本机离线运行，不上传数据。只有 `pull_diag.py` 会连接手机。

| 脚本 | 做什么 |
|---|---|
| `Vendor/LocalVLM/prepare.sh` | 编出离线看图要用的 `PRTSLocalVLM.xcframework`（llama.cpp），并下载、校验 MiniCPM-V 4.7 的权重。clone 下来后先跑一次，不跑 App 编不过，见 [本地视觉模型](../features/local-vlm.md) |
| `validate_spatial.sh` | 跑 SpatialCore 包测试、契约测试、Python 测试，再无签名编译 App |
| `pull_diag.py` | 从连着的手机拷出 App 的 `Diagnostics` 目录 |
| `read_diag.py` | 读 DIAG，`--verify-data` 校验附件 |
| `summarize_session.py` | 汇总旧版 Sessions 导出，不支持 DIAG 目录 |
| `read_dev_capture.py` | 校验开发版录像的索引、附件和校验和，不解码视频，见 [开发版和采集](dev-capture.md) |
| `code_inventory.py --write` | 重新生成 [代码清单](../architecture/code-inventory.md) |
| `replay_routes.swift`、`compare_route_replays.py` | 用录下的数据重放路线规划，对比改动前后 |
| `replay_route_snapshots.swift` | 重放逐行 `{result, options}` 快照 |
| `sync-prts-core.sh` | 更新 `Vendor/PRTSCore`，见 [PRTSCore 包](../architecture/prts-core-package.md) |
| `test_*.py` | 上面这些脚本的测试，直接 `python3 scripts/test_xxx.py` 运行 |

## 重放路线

重放只重跑规划，地面分析和深度用录下来的。中间没录到的帧补不回来，也模拟不了用户走了别的路之后传感器会看到什么。

```sh
swift build --package-path Vendor/SpatialCore
swiftc -O -I Vendor/SpatialCore/.build/arm64-apple-macosx/debug/Modules scripts/replay_routes.swift \
  Vendor/SpatialCore/.build/arm64-apple-macosx/debug/SpatialCore.build/*.swift.o -o /tmp/prts-replay
/tmp/prts-replay /absolute/path/dev-capture-* > /tmp/replay.jsonl
python3 scripts/compare_route_replays.py /tmp/before.jsonl /tmp/after.jsonl
```

- 先用 `read_dev_capture.py` 校验录像。
- 对比前后两次重放时，帧的顺序、epoch、frameID 和时间戳要一致。改算法前先把旧版可执行文件存一份。
- `replay_route_snapshots.swift` 默认用 `obstacle_veto_v1`，加 `--verified` 用 build 16 的严格策略对照。输入如果是从压缩栅格重建的，缺少逐格的原始样本数，要在结论里写明。
- 重放会报告 `confirmedModelFree`：路线有没有碰到确认障碍。旧记录里没有障碍模型时记为 unavailable；同时看 `confirmedModelChecksPresent`，字段缺失不能当成通过。

更完整的离线重放（含指标统计）在 `Experiments/astra`，见 [astra 重放](../experiments/astra-replay.md)。
