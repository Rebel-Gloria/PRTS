# Architecture documentation

- [Code structure](CODE_STRUCTURE.md)
- [Runtime data flow](RUNTIME_DATA_FLOW.md)
- [Forward route policy](FORWARD_ROUTE_POLICY.md)
- [Spatial integration](../SPATIAL_INTEGRATION_2026-09-28.md)
- [Stability fix](../STABILITY_FIX_2026-09-28.md)

The architecture is intentionally split into product UI, capture ownership, spatial runtime, pure algorithms, rendering, feedback, and diagnostics. Changes should preserve those boundaries.

- [代码量与完整源码树](CODE_INVENTORY.md) — 可重复生成，排除模型、构建及实验副本。
- [代码审查与验证](CODE_AUDIT_2026-09-29.md) — 并发隔离、录制边界和测试结果。

- [build16 路线续接、世界证据与发布机制](ROUTE_CONTINUITY_2026-09-29.md) — 当前实现、测试和未完成项。
