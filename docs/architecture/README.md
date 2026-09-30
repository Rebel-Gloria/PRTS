# Architecture documentation

- [Code structure](CODE_STRUCTURE.md)
- [Runtime data flow](RUNTIME_DATA_FLOW.md)
- [Forward route policy](FORWARD_ROUTE_POLICY.md)
- [Spatial integration](../SPATIAL_INTEGRATION_2026-09-28.md)
- [Stability fix](../STABILITY_FIX_2026-09-28.md)

The architecture is intentionally split into product UI, capture ownership, spatial runtime, pure algorithms, rendering, feedback, and diagnostics. Changes should preserve those boundaries.

- [代码量与完整源码树](CODE_INVENTORY.md) — 可重复生成，排除模型、构建及实验副本。
- [代码审查与验证](CODE_AUDIT_2026-09-29.md) — 并发隔离、录制边界和测试结果。

- [build16 路线续接、世界证据与发布机制](ROUTE_CONTINUITY_2026-09-29.md) — 历史实现、测试和未完成项。

- [build17 obstacle-veto](OBSTACLE_VETO_2026-09-29.md) — obstacle-veto 基础策略、滚动续接、测试与安装记录。

- [build18 转向与尾部续接](TURN_TAIL_2026-09-29.md) — 当前修复、回归测试和交付。

- [build25当前代码审计](CODE_AUDIT_2026-09-30.md) — 悬空入口、启停时序、性能机会和本轮测试边界。
