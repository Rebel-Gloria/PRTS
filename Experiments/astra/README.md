本目录是第二轮审查实验，产品源码没有修改。

从仓库根目录运行 `zsh experiments/astra/run.sh /path/to/pull-17pm-1028`，串行完成深度校验、SpatialAnalyzer、规划消融、绘制原型、统计、视频抽帧及报告生成。依赖本机 Swift 工具链、Python 3、NumPy、ffmpeg/ffprobe；不安装依赖，不启动传感器、App 或模拟器。`run.sh` 的链接路径对应本机 Swift 6.4 的默认 swiftbuild 产品布局。所有缓存和产物留在本目录。

文件职责：

- `prepare.py`：输入清单、缺失帧清单、从生产源码生成可审计的实验副本，所有替换都断言唯一命中。
- `Replay.swift`：逐帧解压与 SHA256 校验，调用生产感知、规划、发布策略，实验参数消融、语音请求和触觉策略重算。
- `Drawing.swift`：局部地面、等弧长、受约束圆角、世界高度滤波、身体扫掠复核、等世界宽度及圆连接。
- `metrics.py`、`audit.py`：主指标、缺失敏感性、故障注入、近距代理敏感性；所有真值限制见报告。
- `annotation.py`：逐帧校验视频 PTS 并生成本地标注页面；不会填入人工真值。
- `score_labels.py`：输入人工裁决 CSV 后，按精确 frame ID 计算近距告警精确率/召回率，不补视频之间的标签。
- `results/metrics.json`、`audit.json`：完整统计；`events.csv`：每个近距事件明细；`annotation_manifest.csv`：待填标注表。
- `design.json`：设计参数和未测量的 iPhone 预算目标。

`replay.jsonl`、编译目录及抽帧 JPG 默认忽略，防止把大量实测数据或构建缓存意外加入版本库。交付时它们仍保留在当前工作区，可用上述命令重建。

打开 `results/annotation.html`，为两名标注员使用不同浏览器配置/编号，独立导出，第三人裁决后填回 CSV；只有 `yes/no` 进入计数，其他值排除。米制距离不能从图片可靠确定时必须填 uncertain。查看前后视频时需保留原 DIAG 目录。

评分：`python3 experiments/astra/score_labels.py adjudicated.csv > experiments/astra/results/labeled_metrics.json`。加 `--gold-only` 可只统计有独立米制依据的裁决；不加时视觉估计仍属探索性标签。本次交付的 CSV 没有人工标签，因此不能报告真实精确率/召回率。
