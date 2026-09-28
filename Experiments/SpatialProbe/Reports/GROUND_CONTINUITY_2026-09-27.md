# 地面短暂离开视野：定位、修复与验证

日期：2026-09-27（Asia/Shanghai）。修复版：0.1.0 **build 4**。

## 结论与数据来源

不是每次“看不到地面”都发生ARKit追踪失效。本次直接从已连接的iPhone 15 Pro读取build 3的DIAG，未保存/读取RGB。原始证据保留在：

`/Users/yuanyuan/Desktop/Prts/PRTSTEST/build/diag-motion-20260927-01/2026-09-27T06-17-13Z-5E009013-49CC-436D-BD22-BC7FABACCB44`

- 3,104条已写入capture记录：3,036正常、66初始化受限、2不可用。
- 518条analysis：515有深度，294生成非空表面模型，224没有模型。
- 原因可重叠：地面连续确认不足154、floor先验不足52、参考方向接近竖直46、地面拟合失败17、追踪非正常12。
- 分析完成时源帧年龄P95约94.3ms，最大135.4ms；本次已记录的分析结果未超过250ms上限。
- DIAG记录自身有丢弃：capture70、analysis11、render97、heartbeat2、mesh14；不称作完整无损时间序列。
- 975个深度/网格附件校验成功，无校验错误；实际落盘约65.3MB（十进制）。没有RGB附件。

Apple官方Understanding World Tracking说明世界追踪使用视觉惯性里程计（VIO），结合相机视觉特征与运动传感器数据，并不要求每帧识别到地面。视觉缺少特征、光照不适和剧烈运动仍会使追踪受限，因此不能把它理解为纯IMU长期独立导航。官方文档已读取，核对副本：

`/Users/yuanyuan/Desktop/Prts/PRTSTEST/build/GroundContinuity/apple-world-tracking.json`

官方来源：`https://developer.apple.com/documentation/arkit/understanding-world-tracking`

## 根因

1. 原分析器在任何一次地面拟合失败时reset，丢掉已建立的参考，后续又从3帧确认重新开始。
2. 每一帧表面模型被强制绑定“本帧地面已确认”；即使ARKit位姿正常、其他物体深度正常，蓝/红模型也被清空。
3. 用于方向提示的GroundBasis要求前向地面投影>=0.5，手机俯仰超过约60°时，连不依赖人体前向的表面建模也直接返回。
4. 渲染缓冲只接收当前分析模型，没有独立、带来源和时间上限的历史显示入口。

## 修复

- GroundReferenceTracker保留最后通过原3帧确认规则的世界地面参考：最多2秒、相对来源相机平移<=1米、沿地面法向位移<=0.35米；复用不刷新来源时间。与新floor高度差>12cm或法向差>8°时撤销。
- 持续以当前高置信度深度重建三角面。近期参考不是新的地面/净空观测，不填补未知区域；参考复用期间不生成候选格、方向距离或通道。初次未确认平面/桌面仍不能建立参考。
- 几何地面切向基与方向门控分开。接近竖直时用历史世界前向或确定性世界切向用于几何，不把该方向当成人体朝向。
- 测量短缺时保留一个有界历史表面，最多1秒、平移<=0.75米，以淡色线框在当前相机下重投影；不保留旧阻挡柱、栅格、距离或通道。当前有效空模型及矛盾地面会撤销历史。
- 正常结果250ms过期规则不变；历史仍要求新的normal相机帧。停止、冻结、后台、追踪受限、重定位、参数变更、critical热状态清空缓存。捕获侧失效屏障同步到分析器，覆盖在10Hz间隙发生的短暂追踪异常。
- UI即使关闭HUD也显示“沿用地面参考＋当前深度”或“历史线框、非实时占用/通道”。DIAG加入参考来源/年龄/失效和实际渲染表面模式。
- 未添加独立IMU积分或外部定位模块。仍为SwiftUI＋ARKit＋MetalKit，不改变RGB全视野显示变换。

## 验证

- 82项Swift测试：Debug与Release均通过。包括2秒超时不续命、位移/高度/地面冲突、epoch/参数隔离、重获3帧确认、65/85/90°俯仰、缺floor先验、仅见抬高平台时不造蓝地面、历史线框世界坐标重投影与时效、不得复用候选区、迟到结果不能复活历史。
- 15项Python测试通过，新增对历史渲染与当前几何资格的独立统计。
- iPhoneOS Debug/Release无签名、Simulator Debug、iPhoneOS Release签名构建均通过；codesign严格验证通过。
- 离线重放同一组**506个正常追踪且有深度附件的实测分析帧**：非空表面模型由294/506增至438/506。106帧采用近期地面参考；这些帧候选格/通道/方向距离均为0。未计入历史线框，因此不是把旧图层重复显示计为新模型。
- 重放使用原始深度、置信度、相机位姿、参数及实际floor先验，逐附件校验SHA256，标识source=device_replay；脚本拒绝将模拟器/合成来源标为device_replay。记录缺帧不补造，受限追踪记录用于清理参考。重放不是完整ARSession复现、实时渲染、实机性能或精度/安全验收。

## 安装与待验证项

2026-09-27 14:38（Asia/Shanghai）已将build 4覆盖安装到iPhone 15 Pro（Gloria），未卸载、未删除历史日志。远程启动被系统因**设备锁定**拒绝；解锁后手动打开即可。未宣称修复版真机现场效果已经通过。

建议在受控环境原地测试：

1. 开始后先让有纹理、不反光的地面进入视野，建立蓝色模型。
2. 缓慢抬起/转动手机，让地面短暂离开0.5–1.5秒，然后返回；检查近期参考标签，不能出现旧黄色通道。
3. 原地将手机俯仰到65–90°，检查有当前深度时仍能建模；不要求方向提示继续输出。
4. 缺少有效测量时应看到短暂历史线框标签，而非冻结的彩色实心面；超过限制撤销，不无限保留。
5. 测试停止/后台/恢复及遮挡摄像头，确认旧模型和通道不会跨无效追踪复活。
6. 停止后导出DIAG。需新一轮实测确认画面连续性、参考漂移/误分类、动态目标残留、日志开销和持续发热。

未实现纯惯导长时间定位、室外LiDAR失效补偿、可靠台阶/落差检测。保留的几何不是安全通行证据；所有移动测试由视力正常人员在受控环境进行。

## 证据与实现

证据目录：`/Users/yuanyuan/Desktop/Prts/PRTSTEST/build/GroundContinuity/`

- verified-source-summary.json：原始日志及975附件校验。
- replay-final.json：逐帧离线对照；replay-build-final.log、synthetic-replay-rejection.log：重放工具编译及来源拒绝。
- validation.log：82项Swift（双配置）、15项Python及三种无签名编译。
- signed-release.log、device-install.log、device-launch.log：签名构建、安装成功、锁屏拒绝启动。
- before/、source-changes.patch：修改前文件与Core/App差异。

关键代码：Core/Sources/SpatialCore/GroundReference.swift、SurfaceHistory.swift、Analysis.swift、Geometry.swift、ResultPresentationGate.swift；App/ProbeEngine.swift、Snapshots.swift、ProbeRenderer.swift、ProbeContentView.swift、DiagnosticRecorder.swift；离线工具scripts/replay_diag.swift。
