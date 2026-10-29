# 文档

## 功能

- [拍照描述](features/photo-description.md)：按一下描述画面，按住提问
- [拍照提示词](features/photo-prompt.md)：系统提示词是怎么调出来的
- [文字识别](features/text-reading.md)：三指按住，读纸上的字
- [没有 LiDAR 的机型](features/no-lidar.md)：用 Depth Anything 估深度
- [本地视觉模型](features/local-vlm.md)：MiniCPM-V 4.7 离线描述的实测
- [无障碍](features/accessibility.md)：旁白、大字体、不方便按住的用户
- [设置项](features/settings.md)：正式版和开发版各有哪些设置
- [文案规范](features/copy-guidelines.md)：界面文字和播报怎么写

## 架构

- [代码结构](architecture/code-structure.md)：目录、关键文件、几条规矩
- [运行时数据流](architecture/runtime-data-flow.md)：一帧画面怎么变成播报和震动
- [空间几何](architecture/spatial-geometry.md)：坐标、地面、栅格
- [SpatialCore](architecture/spatial-core.md)：算法包管什么、怎么来的
- [PRTSCore 包](architecture/prts-core-package.md)：旧后端的契约包
- [代码清单](architecture/code-inventory.md)：各模块的行数（脚本生成）

## 开发

- [开发版和采集](guides/dev-capture.md)：编译开发版，录画面和传感器数据
- [DIAG 记录格式](guides/diag-format.md)：自动诊断记录里有什么
- [脚本](guides/scripts.md)：校验、读 DIAG、重放路线

## 实验

- [SpatialProbe 验证 App](experiments/spatial-probe.md)
- [astra 重放](experiments/astra-replay.md)：用实地数据重跑整条避障链
- [拍照提示词评分规则](experiments/photo-prompt-scoring.md)
- [台阶检测提案](experiments/step-detection-proposal.md)
- [障碍地图记忆](experiments/scene-memory.md)：离开视野的障碍继续参与绕行（实验分支）

## 报告

按日期记录当时做了什么、测出了什么。

- [2026-09-30 三态避障](reports/2026-09-30-three-state-guidance.md)（build 24、25）
- [2026-09-30 代码审计](reports/2026-09-30-code-audit.md)
- [2026-10-29 实地复盘和三轮算法审查](reports/2026-10-29-algorithm-review.md)
- [2026-10-29 拍照提示词评估](reports/2026-10-29-photo-prompt-eval.md)

更早的报告（build 2–18）已经删除，需要时翻 git 历史。
