# PRTS 空间感知合并（2026-09-28，主应用 build 12）

## 来源和范围

- 独立测试工程保存于 `Experiments/SpatialProbe`；首个归档提交 `37ef8c2`，分支 `feature/spatial-probe-build11`。
- 用户已确认测试应用 build 11 真机地面绘制恢复。该确认不等于本次主应用移植后已完成真机回归，也不等于所有场景的安全验收。
- 按既定三步规划，本次接入离线基础几何闭环与演示可视化；VLM/Omni、目的地导航和语义物体检测不在本次范围。既有轻量目标检测仍没有已接入的模型，不能把几何红区称为物体语义识别。

## 工程结构

- `Vendor/SpatialCore`：完整迁入经测试的地面估计、保守三态栅格、体积障碍、表面/历史显示、单目尺度追踪、路径搜索、固定目标点、路径时效与触觉策略、诊断格式及197项合成测试。保留原项目的 SceneContracts / FeedbackPolicy 兼容接口，不使用旧版几何实现。
- `PRTS/Spatial`：单一ARSession、最新帧邮箱、Metal渲染、Core ML单目分支、手动空间数据采样和每次启动DIAG。核心运行文件与测试工程一致，只有明确的import及UI宿主适配。
- `PRTS/CameraManager.swift`：原主界面的轻量适配器，不再拥有AVCaptureSession或第二套ARSession。
- `PRTS/CameraPreview.swift`：显示同一引擎、同一坐标变换的Metal画面，完整视野aspect-fit。
- `PRTSBackendBridge.swift`：无大模型运行时；保留目标检测未配置状态与未来消费者协议。`SceneSnapshotAdapter`仅将当前有效、同源帧的实测LiDAR结果导出给兼容语音反馈；不会把单目预测改称实测。完整路径/单目/网格数据仍通过SharedSnapshot的带来源类型访问。
- 语音可提示当前有效障碍；左右/对准触觉只由移植的PathHaptics输出，避免旧反馈协调器同时振动。全局触觉开关、设置页、后台和停止均抑制路径触觉。

## 原主页面恢复

恢复基准是本地main的 `c9bace5`（简体中文设置本地化完成后），而不是尚未提交的离线面板重写。

保持：全屏相机背景、上下渐变、深色青绿主题、PRTS标题和顶部设置按钮、底部状态/命令栏、大按钮及一秒长按停止。只替换数据来源与生命周期接线；状态文案明确是实验候选，命令栏仅支持“开始/停止/状态”，不假装有自然语言模型。

`设置 → 演示模式选项` 控制主页面RGB画面、传感器底图、几何叠加、路径/目标点、参数指标栏和图例。`设置 → 图层、路径、触觉与 DIAG 日志` 保留高级参数和导出。已移除独立技术演示界面；主页面通过HomeDemoOverlay读取同一ProbeViewModel，仍只有一个轮询定时器与一个ARSession。显示偏好跨启动保存；设置内方向振动暂停。

源级回归测试锁定原版header、cameraStatus、primaryButton、stopGesture和主题颜色哈希，并检查算法、未改动运行模块及模型一致性（渲染与着色器已有主页面显示控制适配）。主界面不是对验证版主屏的复制。

## 能力和限制

- LiDAR：原始sceneDepth、confidence、floor网格先验、蓝地面、红突起和上方禁入柱、±45°扇形可达远端固定点、0.50m最小总通道宽度、左右区分触觉及对准滞回。
- 无LiDAR：ARKit追踪/原生平面＋随应用分发的Depth Anything V2 Small F16相对深度，经原生几何校准尺度；不是原生绝对深度，也没有LiDAR置信度。校准不可靠时不冒充有效实测。
- 路径预测不等于安全路线；青色近身连接是未验证部分，历史参考不授权新净空；没有可靠台阶/落差检测。
- DIAG保存深度/置信度/网格及指标，不保存RGB；空间数据仍涉及环境隐私，不自动上传。运行记录、视频、签名凭据、构建产物没有加入Git。
- 第三阶段仅保留接口，未启用VLM、Omni、网络模型API或导航。

## 构建和验证入口

```bash
bash scripts/validate_spatial.sh
# 在自己的Xcode选择有权限的Team，打开PRTS.xcodeproj，保持主应用Bundle ID。
# 真实持续测试建议Release配置；模拟器只验UI和逻辑，不验LiDAR。
python3 scripts/pull_diag.py --device <device-id> --output /tmp/prts-diag-new-run
python3 scripts/read_diag.py /tmp/prts-diag-new-run/<launch-directory> --verify-data
```

主应用bundle仍为 `com.jingxuan.PRTS`；测试应用仍为 `org.prts.SpatialProbe`，并未覆盖其记录。pull_diag默认主应用，可用 `--bundle-id org.prts.SpatialProbe` 读取旧测试应用。

## 保护和回滚

原未提交工作区已完整备份到本机测试目录 `build/MainIntegration0928/before/PRTS-workspace.tgz`，另有未提交补丁与状态清单。没有硬重置、删库或强推；PBX中既有团队/Bundle配置保留，只接入已有本地SpatialCore依赖和同步目录，并更新主应用build为12。

独立测试工程保留在分支首个归档提交；集成提交后通过正常Git merge进入main。需要退回产品UI/后端时使用Git revert相应集成提交，不要误删设备DIAG。

## 2026-09-28 主页面演示叠加

演示功能不是独立运行模式。主页面始终是唯一的实时相机/空间感知宿主；`演示模式选项`只是设置分页，用于控制主页面的显示层。关闭摄像机画面只隐藏RGB，不停止ARSession、空间分析、路径计算或DIAG。关闭叠加层、路径或指标栏也不改变感知结果和反馈逻辑。


显示验证：空间算法197项测试和Python35项检查通过，主应用iPhoneOS Release、Simulator Debug构建通过。显示开关保留旧DIAG RenderOptions解码兼容性。新增UI检查覆盖设置入口和摄像机画面开关；真机叠加位置、横竖屏以及隐藏RGB时的实际渲染仍需实测，不能用模拟器代替LiDAR验收。

模拟器补充验证：7项应用测试通过（包含旧RenderOptions解码及开关往返编码）；1项UI流程通过（原主页控件、演示选项入口、RGB开关、返回后指标栏可见、原高级设置弹窗）。已检查主页面截图，保留原主题与底部按钮；指标栏限定在标题与底部控制之间的可滚动区域。不开启相机也会显示明确的“未采集/暂无结果”，模拟器不伪称有LiDAR数据。本次未安装到真机。
