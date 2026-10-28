# PRTSCore 包

`Vendor/PRTSCore` 是从旧后端仓库复制过来的 Swift 包，固定在一个提交上。App 只链接其中的 `PRTSContracts`（数据结构和测试），代码里没有用到它。避障、拍照描述和文字识别都不依赖它。

- 上游：`https://github.com/Oldcucumber/PRTS_Core.git`，固定在 `main` 的 `0469479b0d6775940b7e50d95b2095fb7d7fedeb`（2026-09-24 核对过）。上游 `main` 有更新时不要跟着动。
- 包里有：契约和测试、部分 Apple 端 Swift 源码、BGRA 相机适配、几个提示音 WAV。没有 `Artifacts/prts_vlm.xcframework` 时编译轻量的 `PRTSAppleModelsLite`，它明确报告模型不可用。
- 没复制：网页端、Python 运行时、测试视频、语音模型、模型权重、XCFramework。

## 更新

只有确实要升级依赖时才运行 `scripts/sync-prts-core.sh`。它只拉脚本里写死的那个提交，只复制选定的源码和测试，不复制模型。升级时先审查候选提交，再同时改脚本里的固定提交和这份文档，跑完全部测试后再提交。
