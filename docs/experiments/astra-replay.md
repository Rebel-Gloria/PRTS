第三轮入口直接构建、执行产品源码；第二轮的插桩原型只保留作历史对照。

在仓库根目录运行：

```sh
# 当前产品：重新复制源码、编译、全套 SpatialCore 测试、2128 帧完整重放、指标
zsh Experiments/astra/run.sh /path/to/pull-17pm-1028
# 基线 → +1…+5，以及基线只加 1、2、3；编译和重放严格串行
zsh Experiments/astra/run_round3.sh /path/to/pull-17pm-1028
```

`run_product.sh label [diag]` 是单次入口。`prepare_product.py` 把指定产品的完整 SpatialCore 包逐字节复制到 `generated/ProductCore/`，语音策略逐字节复制，方向语音策略从 App 文件提取；不修改算法、不打开任何实验开关。`swift build/test` 和小工具 `swiftc` 均使用 `-j 2`。源码、副本、App 调用处、二进制及指标工具的 SHA256 保存在 `product_manifest.json`；`seal_product.py` 在执行后再次核对所有编译输入。`ASTRA_SOURCE_ROOT` 可指定只读源快照，默认用工作区。

`round3_sources.py` 用 `git archive` 读取基线 `bfd37f5`，在临时目录应用 `round3-patches/` 中五项独立产品补丁，构造累积和单项源快照；不修改工作区或 Git 元数据。补丁 SHA256 在 `series.json` 中。最终五项组合应与工作区产品文件逐字节一致。各份实验都重新运行 SpatialAnalyzer、PathPredictor、发布、语音与触觉策略，不复用旧感知输出。成功检查门还在实际 capture tick 上执行产品函数。

`results/round3/<label>/` 保存本次完整 JSONL、指标、源码/二进制指纹、全套测试日志及缺失清单。`metrics_product.py` 复用第二轮 `metrics.py` 的 FN/FP/时延口径；额外区分规划输出与反馈 unknown。绘制同时报告固定的 518 帧旧路线意图样本和当前产品实际路线样本，不能把两者冲突数混用。危险语音是 `canSpeak=true`、每发布帧一次的请求模拟，不是实际播音。

`report_product.py` 从九组结果生成根目录 `ASTRA_ROUND3.md`。产物全部忽略，不写入实测数据，不运行 xcodebuild、App 或模拟器。

第二轮原工具为 `Replay.swift`、`Drawing.swift`、`prepare.py` 等；`run_round2.sh` 仅适用于第二轮的产品源快照。要复现原第二轮结论，应使用基线提交里的原 `run.sh`，不能拿已改变的产品源码冒充旧基线。
