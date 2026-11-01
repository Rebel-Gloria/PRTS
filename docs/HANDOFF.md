# 接续任务（2026-11-01）

仓库：PRTS，分支 main，最新提交 2819511（未完成，标记为 work in progress）。开始前阅读 AGENTS.md。提交身份 Oldcucumber，英文提交说明，不加 AI 署名。8 GB Mac：xcodebuild 加 `-jobs 2`，一次只跑一个重任务。

## 已完成（2819511）
- 删除主界面开始按钮和“按住停止”手势；首页出现即调用 `startCameraFromButton()`，没有停止入口。操作按钮快捷指令和 Magic Tap 只负责“未运行时开始 / 读文字时退出”。
- 设置首页新增“非盲模式”（`ContentView.lowVisionKey = "app.lowVisionMode"`，默认关），开启时弹窗确认。开启后相机照常运行，拍照描述、提问、读文字可用，`ContentView` 中 `quiet` 条件屏蔽避障语音和振动。首次弹出使用说明期间同样静音。
- 删除 `GuidanceButton.swift`；新增 6 条 `settings.lowVision.*` 文案。

## 待完成
1. 让 App 编译通过并确认 CI `app-build` 通过（本次改动未本地编译）。
2. 修 UI 测试（目前无法编译）：`PRTSUITests/PRTSUITests.swift` 中第 36 行、第 170 行附近及屏幕巡览测试（约 259–295 行）仍引用已删除的 `cameraButton`；去掉对它的点击和断言，等待运行改用 `waitForGuidance`（已改为等待 `homeTips` 消失）。巡览中 `camera.press(forDuration: 1.5)` 停止步骤应删除。
3. 清理 `ContentView` 中已无作用的 `isHoldingStop`、`stopHoldTask`、`didCompleteStopHold`、`pointerCannotHold` 等状态。
4. 快捷指令仍叫“开始或停止 PRTS”，现在只能开始：改名（如“开始 PRTS”），更新 `PRTSIntents.swift` 的 phrases 和 `intent.toggle.*` 文案。
5. 更新 6 份使用说明（`PRTS/Features/Settings/UserGuide/*.md`）：删除“再按一次操作按钮停止 / 按住主按钮 1 秒停止 / 轻点开始”等内容，写明打开 App 即开始；增加“非盲模式”一句。同步 `docs/usage.md`、`README.md`、`docs/architecture.md` 中关于开始/停止的描述。
6. 加测试：非盲模式开启需确认、取消后保持关闭；开启后无避障播报（可用单元测试覆盖设置键和 `quiet` 逻辑）。
7. 在 iPhone 17 Pro Max（id 00008150-001928591AC0401C）上跑完整测试：
   `xcodebuild test -project PRTS.xcodeproj -scheme PRTS -configuration Release -destination id=00008150-001928591AC0401C -jobs 2 -allowProvisioningUpdates DEVELOPMENT_TEAM=56PKSY3B35 ENABLE_TESTABILITY=YES -skip-testing:PRTSUITests/PRTSUITests/testCPUWithPreview -skip-testing:PRTSUITests/PRTSUITests/testCPUWithoutPreview`
   UI 测试使用 `XCUIApplication.prts()`（跳过首次使用说明）。

## 需要用户决定
- GPT 的文字识别改动（114a043）在远端设置缺失时静默改用离线识别，不再提示缺什么；是否恢复提示。
- 未跟踪的根目录 `Marketing/`（445 MB）如何处理。
