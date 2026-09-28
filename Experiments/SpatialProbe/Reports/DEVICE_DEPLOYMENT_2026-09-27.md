# 真机编译与安装记录

日期：2026-09-27（Asia/Shanghai）。

- 目标设备：已连接的 iPhone 15 Pro，iOS 26.6.2，开发者模式已开启。
- 工程：PRTSSpatialProbe；保留工程既有自动签名配置及 Bundle ID，没有修改业务源码。
- 配置：Release，Xcode 26.6 (17F113)，iPhoneOS 26.5 SDK。
- 应用：空间感知验证，版本 0.1.0，build 1，`org.prts.SpatialProbe`。
- 编译：`BUILD SUCCEEDED`。
- 签名：Apple Development，工程对应 provisioning profile；`codesign --verify --deep --strict` 通过。
- 安装：devicectl 返回 App installed；没有先卸载应用。
- 启动：11:34:07 成功启动；11:34:35 再次查询，应用进程仍存在（PID 32238）。

本次安装包含蓝色地面、红色突起表面、障碍及其上方红色阻挡柱和已有短候选线。上一轮讨论的 A*、宽路径色带与箭头尚未实现。

## 证据

- `build/DeviceDeployment/signed-build-20260927.log`
- `build/DeviceDeployment/install-20260927.json`
- `build/DeviceDeployment/launch-20260927.json`
- `build/DeviceDeployment/process-check-20260927.json`
- 产物：`build/OnDevice/Build/Products/Release-iphoneos/PRTSSpatialProbe.app`

## 验证边界

本记录确认签名编译、安装、启动及随后进程存在；没有用这些结果代替真实 RGB／深度／置信度对齐、空间模型精度、动态障碍表现或30分钟持续性能验收。尚未保存本次真机传感器截图或测量样本。用户可在应用内点击开始，如系统提示则批准相机权限，再按真机验证清单执行。
