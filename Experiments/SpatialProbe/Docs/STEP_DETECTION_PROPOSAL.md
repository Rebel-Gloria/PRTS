# 台阶／落差检测建议（未实现、待实验）

2026-09-27。build 5只做现有模型参数与DIAG优化，**没有加入台阶识别、深度网络或台阶可通行判断**。

## 推荐路线

优先做“LiDAR多平面／高度结构检测 → VIO时序核验 → 可选RGB深度模型辅助”，不是直接用单目网络替换米制深度。当前单地面模型只回答某处相对一个地面平面是否凸起；不同踏面需要多个有界、带支持证据的局部平面。

ARKit sceneDepth已经是Apple公开的RGB与LiDAR融合深度结果，应用所谓“原始深度”指未选smoothedSceneDepth，不是未处理的LiDAR回波。米制深度、相机内参与当前位姿可用于几何验证；深度缺失/低置信度仍不能视为平地。

## A. 先做可解释几何基线

1. 保留当前支撑地面参考和不确定度，在近距离ROI内，对高置信度深度点建立多高度层栅格；低置信度/遮挡/未扫描单独保留。
2. 检测有限面积的近水平片段及其边界，而不是让最大平面随视野变化直接替换全部地面。比较相邻片段的有符号高度差、法向、宽度、可见踏面深度和空间连接关系。不能只用图像中的水平线判断。
3. 上台阶：当前低位支撑面＋抬高的有限水平面＋可见边界；立面可提供额外支持。重复平行边缘、相近高差/踏面进深可以增加“楼梯结构”证据。孤立平面仍可能是箱子/桌面，不直接认作台阶或可通行。
4. 下台阶：区分“看到了较低的踏面/立面”与“前方没有有效测量”。只有后者时输出“疑似边缘，以下未知”，不能确认落差高度，更不能补成平地。
5. 用ARKit世界坐标重投影核对连续观测，记录源帧、时间、视角和支持像素。行人遮挡、姿态骤变、追踪失效、数据过期时降低状态或撤销。保留参考不算新证据。
6. 第一版输出上/下方向的**疑似台阶**、边缘世界坐标、高差范围、边缘地面距离、宽度及证据质量；红色标出高度边缘/危险结构、灰色保留以下未知。暂不允许候选通道跨越台阶。

不建议凭这轮日志固定台阶高差阈值：没有台阶实测尺寸/标签和脚下支撑位置。高度阈值应结合深度残差/测距范围和独立卷尺标注确定，不能把任意3–5cm噪声都当一级台阶，也不能因低于阈值就视为平整。

## B. 深度模型放在哪一层

### Depth Anything V2 Small / Core ML：便于做手机端对照实验

Apple发布了DepthAnythingV2SmallF16的Core ML包，模型卡列出24.8M参数、约49.8MB包以及历史设备基准。适合尝试在原生工程中低频、异步运行，用RGB推断的结构与LiDAR边缘交叉检查。

该Core ML转换版源自通用Small模型，不应不经核实就将其输出直接当成可靠米制深度。需要与同帧高置信度LiDAR对齐尺度/深度表示，检查空间/时序残差并允许对齐失败；不要在RGB缩放、旋转后漏掉反变换。现场推理可以只用内存里的capturedImage，不保存RGB。

模型卡的abs-rel表格是Core ML与原PyTorch输出的转换对照，并非台阶测量真值；其iPhone 15 Pro Max历史推理时间也不代表本项目iPhone 15 Pro上与ARKit/渲染/DIAG并行的开销。

### Prompt Depth Anything：更贴近RGB＋稀疏LiDAR融合，但需要单独移植验证

作者仓库示例直接输入RGB与192×256的ARKit米制LiDAR深度，输出稠密米制预测；提供Small（25.1M）等版本。这类“深度提示/补全”路线值得作为后续研究对照。

不过作者论文中的主基准使用Large，不能直接把Large成绩套到Small；当前示例为PyTorch/CUDA路径，本项目没有验证Core ML转换、iPhone速度或步行安全效果。LiDAR提示完全失效时，也不能依赖过去的尺度关系继续宣称厘米级距离可靠。

### 明确证据隔离

建议分别保存raw_sceneDepth、ARMesh、learned_relative_depth、learned_prompted_depth及模型版本/源帧/变换/残差。预测更稠密不等于更真实：网络补出的踏面不能直接授权可通行、不能覆盖传感器未知或消除疑似落差。

当前DIAG不保存RGB，能重放LiDAR几何，却不能用这批日志离线评估RGB深度模型。未来可做现场内存推理＋仅导出预测数值；若需要图像回放或人工视频标注，要另行确认图像保存范围。

## C. 测试设计

先验证单个上台阶、单个下台阶和路缘，再验证多级楼梯；与坡道、平地条纹、地毯边、箱子、桌面、反光面和人遮挡做对照。用卷尺/明确参考点记录高差、踏面进深、边缘位置及参考测量误差。

主要指标：危险边缘漏检/误检、首次发现距离、边缘定位和高差误差、下方未知比例、检测连续性、输出延迟、热状态；把危险区域错误授权为候选的事件单独列出，不能用平均误差掩盖。

所有测试由视力正常人员在受控环境进行；先原地静态观察台阶，设旁观保护，不开展无保护盲行。现阶段不据此指导实际上下楼。

## 已核对的一手资料（2026-09-27）

- Apple ARDepthData / confidenceMap：`https://developer.apple.com/documentation/arkit/ardepthdata`、`https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap`
- Apple Explore ARKit 4：`https://developer.apple.com/videos/play/wwdc2020/10611/`（RGB与LiDAR融合、深度及置信度说明）
- Apple Core ML模型卡：`https://huggingface.co/apple/coreml-depth-anything-v2-small`
- PromptDA作者仓库：`https://github.com/DepthAnything/PromptDA`
- 可选的后续对照Apple Depth Pro：`https://github.com/apple/ml-depth-pro`；仓库GPU基准不是iPhone并行运行实测，本阶段不接入。

模型卡/作者README的只读核对副本位于项目build/ParameterTuning/research；未下载模型权重、未安装推理框架、未修改系统配置。
