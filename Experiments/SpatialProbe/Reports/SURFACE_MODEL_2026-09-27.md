# 地面突起及上方红色阻挡柱：实现与验证

日期：2026-09-27。

## 实现

- 新增当前原始深度表面模型：确认地面蓝色，达到默认5 cm相对高度且有空间支持的突起／物品表面深红色。
- 新增红色阻挡柱：有至少2个4邻接障碍格、6个支持点、1 L分辨率相关几何包络时，将该占地从地面延伸至配置身体检查高度（默认1.8 m）。物体上方使用半透明红色与红色轮廓，明确为派生禁入范围，不是实测空气占用。
- 柱子只覆盖实际支持格，不填外接矩形，不跨未知缺口，不累计跨帧残影。
- 默认启用，可在设置中关闭阻挡柱或切回原分类／栅格投影。红色模型和柱体不改变原有障碍膨胀和通道禁止规则。
- 地面未确认、追踪异常、方向不稳、数据过期时撤销模型；蓝色地面不等于可通行。
- 日志增加模型／阻挡柱摘要与建模耗时；手动同帧样本保留完整三角面和柱参数。

## 实际执行验证

|项目|结果|
|---|---|
|Swift核心 Debug|43/43通过，0失败|
|Swift核心 Release|43/43通过，0失败|
|Python报告工具|5/5通过|
|iPhoneOS Debug unsigned|BUILD SUCCEEDED|
|iPhoneOS Release unsigned|BUILD SUCCEEDED|
|iOS Simulator Debug|BUILD SUCCEEDED|

43项核心测试包含既有25项、新增表面模型10项、阻挡柱8项。新测试覆盖平地／凸起相对高度、倾斜地面、缺置信度、低突起灰区、孤立异常点、粗采样未抽中坏点、帧／代次隔离、旧样本兼容、障碍上空延伸、未知空隙／L形缺角不补齐、最小支持、身高设置、障碍移除和无效高度。

构建环境 Xcode26.6 (17F113)，iPhoneOS26.5 SDK。只有未使用AppIntents而跳过元数据提取的构建警告。

日志：`build/surface-validation-full.log`，以及`build/core-tests.log`、`build/core-release-tests.log`、`build/report-tests.log`、`build/device-build.log`、`build/device-release-build.log`、`build/simulator-build.log`。

## 尚未验证

本次没有将修改安装到真实iPhone，没有取得蓝／红三维表面或阻挡柱的真机截图，没有测量新增建模开销的真机热／持续性能。代码测试使用明确的合成场景，不是设备感知证据。按 `Docs/DEVICE_VALIDATION.md` 的新增项目进行受控验证；不进行无保护盲行。

详细判定与限制：`Docs/SURFACE_MODEL.md`。源码指纹：`Reports/source-sha256-2026-09-27.json`。2026-09-20报告和截图是历史版本证据，不是新增功能的真机验收。
