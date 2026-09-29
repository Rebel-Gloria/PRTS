> **2026-09-29 / build 17 — obstacle-veto：** 主路线仅由确认障碍否决，unknown、地面/净空证据和证据时效不再阻断。保留世界坐标、提前续接与原子换线，默认前向缓存 8 m。实现和验证见 [本轮报告](docs/architecture/OBSTACLE_VETO_2026-09-29.md)。

> **2026-09-28 / build 12：** 空间感知后端已由经过实机测试的 Spatial Probe 替换，主页面恢复原结构与青绿主题。详见 [集成说明](docs/SPATIAL_INTEGRATION_2026-09-28.md)。离线几何与技术演示可用；第三阶段大模型、语义目标检测未接入。下文旧阶段记录不代表当前后端仍使用旧实现。

# PRTS

PRTS 当前默认运行“第一阶段完全离线基础感知”：单一 ARKit 会话、LiDAR scene depth/置信度、mesh floor prior、本地三态栅格、近场障碍与短距离左／中／右观测候选通道、同源 SwiftUI/语音/触觉反馈。

当前实现局部路线引导，不接入目的地服务、GPS 或 ARWorldMap，也不连接 VLM、Omni、vLLM 或模型 API。原始三态栅格保留测量含义；独立规划栅格开放全部非确认障碍区域。路线以世界坐标保存在当前会话内。

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

默认沿保留的前向贪心延长路线，提前填充前向缓存；确认障碍侵入时绕行。小障碍回归原线，宽障碍改选侧向路线。障碍从当前模型消失即可恢复直线，不等待自由空间确认。偏离当前路线 45°、稳定保持 3 秒且新方向可规划时采用新前向。
模块拆分、阈值、日志、语音及待完成实机验收见 [路线策略说明](docs/architecture/FORWARD_ROUTE_POLICY.md)。

代码量与完整文件树：[CODE_INVENTORY](docs/architecture/CODE_INVENTORY.md)。
本轮审查与验证：[CODE_AUDIT](docs/architecture/CODE_AUDIT_2026-09-29.md)。

晚间录制回放与路线优化：[对照报告](docs/architecture/ROUTE_REPLAY_2026-09-29.md)。
