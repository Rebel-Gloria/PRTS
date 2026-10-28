# astra 重放

`Experiments/astra` 用实地录下的 DIAG，在 Mac 上把主 App 的整条避障链（分析、规划、发布、播报、震动）完整重跑一遍，统计漏报、误报和延迟。改算法前后各跑一次，就能比较改动的效果。名字来自做算法审查的模型 GPT-6-Astra。

## 怎么跑

在仓库根目录：

```sh
# 当前产品：复制源码、编译、跑全套 SpatialCore 测试、重放 2128 帧、算指标
zsh Experiments/astra/run.sh /path/to/pull-17pm-1028

# 第三轮对照：基线，加上第 1 到第 5 项改动，以及基线只加 1、2、3
zsh Experiments/astra/run_round3.sh /path/to/pull-17pm-1028
```

`run_product.sh <label> [diag]` 跑单个版本。`ASTRA_BODY_WIDTH=0.4` 这类环境变量可以临时改身体宽度。编译和重放都是串行的，`-j 2`，适合 8 GB 的 Mac。

## 它怎么保证测的是产品代码

- `prepare_product.py` 把 SpatialCore 整个包逐字节复制到 `generated/ProductCore/`，播报策略逐字节复制，方向播报策略从 App 源码里提取。不改算法，不开实验开关。`ASTRA_SOURCE_ROOT` 可以指定一个只读的源码快照。
- 源码、副本、二进制和指标工具的 SHA-256 写进 `product_manifest.json`，`seal_product.py` 跑完后再核对一遍。
- `round3_sources.py` 用 `git archive` 取出基线 `bfd37f5`，在临时目录打上 `round3-patches/` 里的 5 个补丁，生成累积和单项的源码快照，不碰工作区。5 个补丁全打上应该和工作区的产品代码一模一样。
- 每个版本都重新跑感知，不复用旧结果。

## 结果

- `results/round3/<label>/`：完整的 JSONL、指标、源码和二进制指纹、测试日志、缺失清单。
- `metrics_product.py` 沿用第二轮 `metrics.py` 的漏报、误报和延迟算法，另外区分规划输出的 unknown 和反馈的 unknown。
- 绘制指标同时报告固定的 518 帧旧路线样本和当前产品实际的路线样本，两者的冲突数不能混在一起。
- "危险播报"是按 `canSpeak=true`、每个发布帧一次模拟的请求，不是真的播出来了。
- `report_product.py` 把九组结果汇总成根目录的 `ASTRA_ROUND3.md`。

产物都被 git 忽略，不提交实测数据。整个过程不跑 xcodebuild、App 或模拟器。

## 第二轮的工具

`Replay.swift`、`Drawing.swift`、`prepare.py`、`run_round2.sh` 是第二轮的插桩原型，只适用于当时的源码。要复现第二轮的结论，得用基线提交里的 `run.sh`。三轮的结论见 [reports](../reports/)。
