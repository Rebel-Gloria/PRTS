# 代码审查与规范化 — 2026-09-29

## 范围

沿现有 Main 项目的采集、计算、路径状态、渲染发布、反馈和记录链路审查。
保留上一轮尚未提交的前向优先规划实现，不移动源码目录，不重建 Xcode 工程，不调整主页布局或主题。
算法仍在 SpatialCore，ARKit/模型适配在 Runtime，显示在 Rendering/UI，播报与振动在 Feedback。
这不是对所有运行时条件的穷尽证明；本轮未连接真机验收，也没有提交或推送。

## 本轮修复

| 问题 | 修复与边界 |
|---|---|
| 默认 MainActor 导致后台日志编码的 Codable/Encodable 隔离告警 | 日志值类型、网格/显示参数值类型显式 nonisolated；没有把 UI 对象解除隔离或增加 unchecked Sendable |
| 后台平面快照调用 MainActor 隔离的矩阵转换 | RigidPose 的纯矩阵转换初始化显式 nonisolated |
| 嵌套主线程 Task 捕获可变 weak self 的并发告警 | 内层 Task 使用独立 weak 捕获，UI 写入继续在 MainActor |
| RouteSpeechCue 的 Equatable conformance 在测试宏中跨 actor 使用 | 纯枚举显式 nonisolated，不改变播报内容 |
| SwiftUI 旧版 onChange 回调弃用 | 改用 iOS 17 双参数回调，事件条件和处理内容不变 |
| 重复开启 Dev Capture 重置节流时间 | enable 在已开启状态下幂等，重复调用不再绕过 5 Hz 限制 |
| Dev Capture 非有限时间戳可能进入视频时间轴 | 接收入口拒绝 NaN/Inf，创建媒体文件前拦截 |
| 转向保持计时未校验当前方向 NaN/Inf | 无效方向清空持续时间；去除该计时器的强制解包，保留有效输入的原有阈值 |
| 录制测试“10 秒”等待按循环次数而非真实时间判断 | 使用 ContinuousClock 单调截止时间；不延长或删除原 10 秒上限 |

并发边界新增必要注释，源码一致性测试仅放行明确的值类型隔离注解；算法、主页及模块边界检查继续执行。
没有通过关闭编译诊断、放宽未知区域规则或删除失败断言来消除问题。

## 验证记录

日志位置：`/tmp/prts-audit/`（本机临时验证目录，不作为需提交的构建产物）。

- SpatialCore Debug / Release：各 218 项通过。
- Python 工具/结构回归：42 项通过（新增库存统计测试）。
- App Dev Tag 模拟器全套：两轮各 14 项通过，包括无标定 DA 数据、视频/深度配对、
  重复 enable 保持节流以及非法时间戳不创建文件。
- 普通 iPhoneOS Release 与 Dev Tag iPhoneOS Release：无签名构建均通过。
- 本轮源码编译告警清理目标：并发隔离、weak 捕获、onChange 弃用。
  Xcode 的“未依赖 AppIntents，跳过元数据提取”提示保留，不为消除此提示引入无关框架。

上轮首次录制超时在本轮完整测试中未复现；不能仅由测试通过就断言已确定首次冷启动超时的根因。
媒体框架冷启动、模拟器负载与真机持续录制仍需实测；本轮没有重写视频编解码链路。
模拟器还有系统语音库 fallback/AX 运行时提示，测试通过不意味着真实设备语音交互已验收。

## 代码树与统计

完整源码树和分组计数由 `scripts/code_inventory.py` 生成，见 [CODE_INVENTORY.md](CODE_INVENTORY.md)。
模块职责仍以 [CODE_STRUCTURE.md](CODE_STRUCTURE.md) 为准。
统计包含未提交源码；物理行包含注释和空行，非空行包含注释。不是可执行语句数。
排除模型、图片、文档、配置、构建产物及 Experiments 冻结副本，避免重复统计。

## 尚需验证

- 真机绕行/回归原线/主动转向的路线保持与播报；本轮不改变这些策略阈值。
- LiDAR 与无 LiDAR 分支的真实传感器丢帧、热状态和长时间视频采集。
- 设备声库、权限、前后台和真实硬件编码器启动耗时。
- 未来完整 Swift 6 迁移需单独验证；本轮未改变工程的语言模式或默认 actor 设置。
