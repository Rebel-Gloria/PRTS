> **2026-09-29 / build 16 — 路线连续性第 1 轮：** 已接入世界坐标证据、原子换线、提前续接与即时危险否决；Dev 采集不再切换规划策略。范围、真实测试、旧记录回放的 0/110 主路线结果及后续项见 [本轮实施报告](docs/architecture/ROUTE_CONTINUITY_2026-09-29.md)。尚未完成新版本的受控行走验收。

> **2026-09-28 / build 12：** 空间感知后端已由经过实机测试的 Spatial Probe 替换，主页面恢复原结构与青绿主题。详见 [集成说明](docs/SPATIAL_INTEGRATION_2026-09-28.md)。离线几何与技术演示可用；第三阶段大模型、语义目标检测未接入。下文旧阶段记录不代表当前后端仍使用旧实现。

# PRTS

PRTS 当前默认运行“第一阶段完全离线基础感知”：单一 ARKit 会话、LiDAR scene depth/置信度、mesh floor prior、本地三态栅格、近场障碍与短距离左／中／右观测候选通道、同源 SwiftUI/语音/触觉反馈。

它不是目的地导航应用，不保存路线、不使用地图/定位/ARWorldMap，也不连接 VLM、Omni、vLLM 或模型 API。未观测区域始终保持未知；候选通道不代表安全路线。

实现、验证、真机待验收项和下一阶段接口见：

- `docs/PHASE1_OFFLINE_PERCEPTION.md`
- `Vendor/SpatialCore/PROVENANCE.md`
- `docs/OBJECT_DETECTOR_MANIFEST_TEMPLATE.md`
- `docs/architecture/CODE_STRUCTURE.md`
- `docs/architecture/RUNTIME_DATA_FLOW.md`
- `PRTS/README.md`

### 可选开发信息采集包

显式使用 `PRTS_DEV_CAPTURE` 才编译信息采集入口及录像代码，普通包不包含。
开发包仍默认关闭，手动启用后保存低帧率压缩RGB与同帧ARKit/DA输出、分析结果。
编译、使用、隐私及回放格式见 [开发采集说明](docs/DEV_CAPTURE.md)。

### 正前方路线与局部避障（2026-09-29）

默认沿正前方贪心延伸观测路线，目标随新观测滚动前移；实际通行带出现障碍即预规划绕行。小障碍尽量回归原线，宽障碍改选侧向路线。build16 默认策略不再把站着转手机 3 秒视为行走意图；当前可通过停止／开始选择新的前向。完整移动意图处理留待下一轮。
模块拆分、阈值、日志、语音及待完成实机验收见 [路线策略说明](docs/architecture/FORWARD_ROUTE_POLICY.md)。

代码量与完整文件树：[CODE_INVENTORY](docs/architecture/CODE_INVENTORY.md)。
本轮审查与验证：[CODE_AUDIT](docs/architecture/CODE_AUDIT_2026-09-29.md)。

晚间录制回放与路线优化：[对照报告](docs/architecture/ROUTE_REPLAY_2026-09-29.md)。
