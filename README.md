> **2026-09-30 / build 25 — 路线与播报稳定性：** 保持绕行目标、场景迟滞、语义播报限频；修复确认障碍旧中心及窗口裁剪导致的漏检查。见 [日志分析与修复](docs/architecture/WAYPOINT_STABILITY_2026-09-30.md)。

> **2026-09-30 / build 24 — 三态障碍引导：** 空旷只播报；远障先接近；近障逐点绕行。当前点与可调整的下一点分开，支持静止转向、目标出画与受阻重规划。见 [算法与回归说明](docs/architecture/OBSTACLE_WAYPOINTS_2026-09-30.md)。

> **2026-09-30 / build 23 — 长按简洁回答：** 语音提问前加入面向盲人的简短回答提示词；短按描述、播报音色和交互不变。见 [功能与验证记录](docs/PHOTO_DESCRIPTION.md)。

> **2026-09-30 / build 22 — 统一朗读音色：** LLM拍照回答沿用应用播报音色、语言与语速设置；A/B音和长按交互不变。见 [功能与验证记录](docs/PHOTO_DESCRIPTION.md)。

> **2026-09-30 / build 21 — 提示词契约修复：** 短按补齐“一句到两句话”要求，长按仍仅使用识别文字；独立文本契约先失败、修复后35项App测试通过。见 [功能与验证记录](docs/PHOTO_DESCRIPTION.md)。

> **2026-09-30 / build 20 — 拍照交互回归：** 修复UIKit布局覆盖图标透明度的问题；补齐取消、录音顺序、图像四方向与音频配置测试。Dev包已安装启动，App测试34项通过；真实接口与音频仍待实测。

> **2026-09-30 / build 19 — 按需拍照描述：** 中心摄像头按钮短按描述、长按语音提问；独立原生朗读、钥匙串配置。Dev包已安装并启动；真实服务和音频体验待实测。见 [功能与验证记录](docs/PHOTO_DESCRIPTION.md)。

> **2026-09-29 / build 18 — 转向与尾部续接修复：** 新朝向独立查询同一障碍模型，恢复侧转/回头保持 3 秒重选；直线整段检查、合并共线节点，侧向路线提前续接。详见 [本轮修复与测试](docs/architecture/TURN_TAIL_2026-09-29.md)。

> **2026-09-29 / build 17 — obstacle-veto：** 主路线仅由确认障碍否决，unknown、地面/净空证据和证据时效不再阻断。保留世界坐标、提前续接与原子换线，默认前向缓存 8 m。实现和验证见 [本轮报告](docs/architecture/OBSTACLE_VETO_2026-09-29.md)。

> **2026-09-28 / build 12：** 空间感知后端已由经过实机测试的 Spatial Probe 替换，主页面恢复原结构与青绿主题。详见 [集成说明](docs/SPATIAL_INTEGRATION_2026-09-28.md)。离线几何与技术演示可用；第三阶段大模型、语义目标检测未接入。下文旧阶段记录不代表当前后端仍使用旧实现。

# PRTS

PRTS 当前默认运行“第一阶段完全离线基础感知”：单一 ARKit 会话、LiDAR scene depth/置信度、mesh floor prior、本地三态栅格、近场障碍与短距离左／中／右观测候选通道、同源 SwiftUI/语音/触觉反馈。

当前实现局部路线引导，不接入目的地服务、GPS 或 ARWorldMap，不连接本地 VLM、Omni 或 vLLM。新增按需云端拍照描述，与路线规划分离，默认不发送图片；见 [拍照描述](docs/PHOTO_DESCRIPTION.md)。原始三态栅格保留测量含义；独立规划栅格开放全部非确认障碍区域。路线以世界坐标保存在当前会话内。

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

build24默认按空旷、远障（>2m）、近障（≤2m）三态引导：空旷不画线，远障设置障碍前至少0.5m的接近点，近障沿检查后的绕行折线逐点交接。下一点只预备、不提前播报；当前点到达、出画、受阻或静止偏转3秒时更新。障碍模型与非障碍栅格可搜索的语义不变。
模块拆分、阈值、日志、语音及待完成实机验收见 [路线策略说明](docs/architecture/FORWARD_ROUTE_POLICY.md)。

代码量与完整文件树：[CODE_INVENTORY](docs/architecture/CODE_INVENTORY.md)。
本轮审查与验证：[CODE_AUDIT](docs/architecture/CODE_AUDIT_2026-09-29.md)。

晚间录制回放与路线优化：[对照报告](docs/architecture/ROUTE_REPLAY_2026-09-29.md)。
