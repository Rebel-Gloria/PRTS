# 接续任务

本文记录自动启动与非盲模式改动的交付状态，以及尚需完成的真机验证。

## 已完成

| 项目 | 结果 |
|---|---|
| App 编译 | 交接版本 `fece74a` 的 App 编译通过；`8203d35` 的 App、单元测试与 UI 测试目标编译通过 |
| UI 测试修复 | 移除已删除按钮的引用，等待明确的“避障中”状态；更新首页边界检查 |
| 首页状态清理 | 删除停止手势状态，保留辅助触控提问入口；将旁白“读文字”操作迁移至相机状态 |
| 快捷指令 | 显示名称及短语改为“开始 PRTS”，保留原 intent 类型以兼容已有快捷指令 |
| 使用说明 | 更新六份使用说明、README、功能操作和架构文档 |
| 非盲模式测试 | 增加确认、取消、关闭和恢复设置的 UI 测试，以及反馈静音策略测试；启动状态反馈也使用同一静音策略 |
| 验证 | 53 项仓库检查、4 种静音组合验证通过；`8203d35` 的格式检查、空间与契约测试、App 与测试目标编译均通过 |

## 待完成

在已连接的 iPhone 17 Pro Max 上执行完整测试。目前 SSH 可登录 Mac，但系统拒绝读取 Documents 中的工作副本；需开放目录访问或提供可访问的完整副本。CI 使用模型占位库，只证明可编译，不代替真机测试。

8 GB Mac 一次只运行一个重任务，使用：

```sh
xcodebuild test -project PRTS.xcodeproj -scheme PRTS -configuration Release -destination id=00008150-001928591AC0401C -jobs 2 -allowProvisioningUpdates DEVELOPMENT_TEAM=56PKSY3B35 ENABLE_TESTABILITY=YES -skip-testing:PRTSUITests/PRTSUITests/testCPUWithPreview -skip-testing:PRTSUITests/PRTSUITests/testCPUWithoutPreview
```

提交身份和格式遵循根目录 `AGENTS.md`。每项修改单独提交并推送；不得覆盖其他未提交改动。

## 需要用户决定

- 远端文字识别设置缺失时，是否恢复配置提示；当前保留静默本机回退。
- 原 Mac 上未跟踪的根目录 `Marketing/`（交接记录约 445 MB）如何处理；当前 Windows 工作副本没有该目录，未作删除或迁移。
