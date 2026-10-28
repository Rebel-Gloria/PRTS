# 台阶检测提案

还没做。现在的地面模型只有一个局部平面，只能判断"某处比这个平面高出多少"，分不出台阶、坡道和路缘。这份提案写的是打算怎么做。

## 思路

先用 LiDAR 几何做一个看得懂的基线，再考虑深度模型；不直接用单目网络代替米制深度。

1. 在近处建多层高度栅格，找出多个有边界的近水平片段，比较相邻片段的高度差、法向、宽度、踏面进深和连接关系。不能只看图像里的水平线。
2. **上台阶**：低处的支撑面，加上一个抬高的有限水平面，再加上可见的边界；立面是额外支持。重复的平行边缘、相近的高差和进深说明是楼梯。孤立的平面可能是箱子或桌面。
3. **下台阶**：分清"看到了更低的踏面"和"前面根本没测到"。只有后者时只能说"疑似边缘，下面未知"，不能把它当平地。
4. 用 ARKit 世界坐标核对连续几帧的观测；遮挡、姿态突变、跟踪丢失时降级或撤销。
5. 第一版只输出：疑似上/下台阶、边缘位置、高差范围、边缘距离、宽度和证据质量。路线暂不允许跨过台阶。

台阶高差的阈值要用卷尺实测的台阶来定，现在的日志里没有这种标注。

## 深度模型

- **Depth Anything V2 Small（Core ML）**：Apple 有官方包（24.8M 参数，约 49.8 MB），主 App 的无 LiDAR 分支已经在用。可以低频异步跑，和 LiDAR 的边缘互相印证。它的输出是相对值，要用同帧的高置信度 LiDAR 对齐。
- **Prompt Depth Anything**：输入 RGB 加 192×256 的 ARKit LiDAR 深度，输出稠密的米制深度，正好是"RGB + 稀疏 LiDAR"的思路。但现在只有 PyTorch/CUDA 版，Core ML 转换和手机速度都没验证过，论文成绩也是 Large 版的。

不管用哪个，预测出来的踏面都不能当成可以走，也不能覆盖传感器的"未知"。原始深度、网格、模型输出要分开存，并记下模型版本和对齐残差。现在的 DIAG 不存 RGB，所以没法用旧日志离线评估 RGB 深度模型。

## 怎么测

先测单级上台阶、单级下台阶、路缘，再测多级楼梯；对照组有坡道、条纹地面、地毯边、箱子、桌面、反光面和行人遮挡。用卷尺记高差、进深和边缘位置。

看这些指标：危险边缘的漏检和误检、首次发现的距离、边缘位置和高差误差、下方未知的比例、连续性、延迟、发热。把危险区域被当成可走的情况单独列出来。

测试由视力正常的人在受控环境里做，先原地静止观察，旁边有人保护。

## 资料

- Apple ARDepthData：https://developer.apple.com/documentation/arkit/ardepthdata
- WWDC20 Explore ARKit 4：https://developer.apple.com/videos/play/wwdc2020/10611/
- Depth Anything V2 Core ML：https://huggingface.co/apple/coreml-depth-anything-v2-small
- Prompt Depth Anything：https://github.com/DepthAnything/PromptDA
- Apple Depth Pro：https://github.com/apple/ml-depth-pro
