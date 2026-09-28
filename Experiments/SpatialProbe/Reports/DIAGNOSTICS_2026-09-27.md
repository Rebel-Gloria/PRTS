# DIAG 交付与验证记录

日期：2026-09-27（Asia/Shanghai）。版本：0.1.0 build 3。

## 已实现

- 每次应用启动自动建立Diagnostics目录；不依赖点击开始、ARSession成功或相机授权。
- 自动记录相机帧元数据、深度／置信度分析帧、网格更新、几何判定、绘制与GPU／呈现阶段、权限／前后台／会话事件、热状态和资源状态。
- 深度数据保留原始Float32位模式，缺失置信度明确区分，不用默认高置信度替代；带位姿／内参／参数／epoch／时间及实际floor先验。
- 无损压缩、分段、SHA256校验；有界记录队列和磁盘限额；明确记录丢弃、失败、队列压力及日志本身耗时。
- 当前及历史记录可在设置导出；提供Python读取、校验、提取深度和设备容器复制脚本。
- 自动记录和新手动样本均不保存RGB／视频／音频／GPS；旧版本保存的历史图像未删除。
- 感知判定阈值没有放宽；新增独立地面连续确认、floor先验、参考方向与显示门控原因。

## 已完成验证

|项目|结果|
|---|---|
|Swift确定性测试|70项，Debug／Release均0失败|
|Python报告／DIAG读取测试|14项，0失败|
|iPhoneOS Debug无签名编译|通过|
|iPhoneOS Release无签名编译|通过|
|Simulator Debug编译|通过|
|iPhoneOS Release既有Team签名编译|通过，保留原Team／Bundle ID|
|codesign严格验证|通过|
|Swift压缩 → Python解压／SHA256／深度解析|通过，数据标记synthetic|
|模拟器启动自动建日志|通过：相机未开启已有manifest、events、heartbeat、status|
|再次启动独立目录／历史保留|通过|
|最终模拟器运行|manifest为build 3、source=simulator_no_LiDAR_evidence；无错误、丢记录或RGB文件|
|主界面检查|DIAG容量／丢弃／状态可见，模拟器能力缺失明确显示|

新增测试覆盖压缩及Float32精确保留、缺置信度、数据统计、启动记录、历史导出、队列满／内存界限／事件槽位、单次／总配额、分段、编码失败、非有限数、路径越界、文件截断／校验失败和读取器提取。

## 真机状态与未验证内容

最终设备查询中，已配对的iPhone 15 Pro状态为 **unavailable**。本轮没有安装或启动build 3到该手机；手机上已有build 2不能视为包含此功能。

以下待设备恢复连接后验收：

- 真机启动／相机授权拒绝／开始停止／前后台时的记录连续性；
- 实际ARKit深度、置信度、网格附件及现场失效原因；
- 分析／绘制／日志开销、队列丢弃、实际压缩率和持续30分钟热状态；
- 接近磁盘限额、设备锁定和系统终止时的实际行为。

模拟器和合成数据不构成LiDAR功能或步行安全验收。日志不保证在突然强杀／断电时保住最后写入，也不会把记录队列丢弃的帧伪装成完整回放。

## 使用与证据

说明：`Docs/DIAGNOSTICS.md`。

证据目录：`build/DiagImplementation/`

- `validation-final.log`：完整测试与三种无签名编译。
- `signed-release-build.log`、`signature-check.log`：签名构建和验证。
- `synthetic-launch/`、`synthetic-summary-final.json`：明确标识synthetic的跨语言格式验证。
- `simulator-final-summary.json`、`simulator-main-ui.png`：模拟器启动记录和UI检查，不是现场图像。
- `device-availability.log`：真机不可连接状态。
- `before/`、`source-changes.patch`、`source-sha256.json`：修改前备份、差异和当前源码哈希。

安装产物：`build/OnDevice/Build/Products/Release-iphoneos/PRTSSpatialProbe.app`。
