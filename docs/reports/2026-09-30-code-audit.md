# 2026-09-30：代码审计（build 25）

对 build 25 做了一次只读审计：理清真实的调用链，找没人调用的方法，列出可能的问题和可以优化的地方。悬空方法后来都在清理时删掉了；下面三个问题到 2026-10-29 还没有处理。

## 还没处理的问题

**A1（P1）开始和停止之间没有请求代次。** `ProbeEngine.start(device:)` 把启动闭包排进 sessionQueue；`stop(reason:)` 立即把 `running` 设成 false，再排一个 pause。如果顺序变成"start 入队 → stop 清状态并入队 pause → 旧的 start 执行，写回 running=true"，状态就会和实际不符。权限弹窗刚确认就切后台，是值得试的场景。代码路径确实存在，但没有复现过，也没证明和路线抖动有关。建议给启停加请求代次，排队的闭包执行前核对代次。

**A2（P2）读诊断会阻塞写诊断。** `DiagnosticJournal` 的 `listRuns`、`export`、`size` 在写日志的同一个串行队列上递归统计大小、复制整个目录。避障还在跑时，写入要等，队列满了就丢记录。建议：列表用缓存的大小，导出先在写队列定好文件边界，再交给单独的 I/O 队列复制。

**A4（P2）网格显示缓存反复清空。** `ProbeRenderer.updateMeshBuffers` 每次绘制会删掉所有版本不匹配的旧缓冲，但每次只上传一个 anchor。网格持续更新时，没轮到的 anchor 会暂时没东西画，看起来像网格缺块。只影响显示，不影响路线。建议按 anchor 合并待上传版本，后台生成顶点，传完再整体替换。

另外，开发版录像的结束路径（A3）和那次排空超时也没查清，见 [三态避障报告](2026-09-30-three-state-guidance.md)。

## 可以优化的地方

| 位置 | 现在 | 可以怎么改 |
|---|---|---|
| `ProbeEngine.session(didUpdate:)` | 每次提交分析都排序、展开全部 floor 先验 | 网格版本变了再重建先验数组 |
| `DevCaptureRecorder.submit` | 先整理平面、特征点、网格，再判断要不要这一帧 | 先占采样名额，通过了再整理 |
| `OccupancyFootprint.stamp` | 每个格子每个轴都重复算角点投影 | 每个足迹预先算好投影区间 |
| `CoreMLDepthModel.prepareInput` | 每次新分配输入缓冲 | 用 CVPixelBufferPool 复用 |
| `ProbeRenderer.updateMeshBuffers` | 只选一个网格却全量排序 | 单遍选出 |
| `ProbeViewModel.poll` | 每次都给所有 Published 属性重新赋值 | 先比较，有变化再赋值 |
| `FanPathSearch.plan` | 绕行分支可能重复搜索 | 先统计搜索次数再考虑缓存 |

改这些都要先证明输出不变：同样的输入，先验、足迹、路线逐项一致。
