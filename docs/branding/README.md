# PRTS 标识资源

用户提供的 SVG 原稿保存在此目录，不改变图形、颜色或字标。

- `app-logo-prts.svg`：iOS AppIcon，渲染为1024×1024、不含透明通道的PNG；浅色、深色和tinted槽使用同一原稿。
- `app-logo.svg`：主页左上角 HomeLogo，32pt，提供1×/2×/3× PNG。保留黑底白色原稿，不按主题色染色。

SVG含mask，资源使用WebKit忠实渲染后的PNG，避免不同SVG资源处理器的mask兼容性差异。原稿带字版本为轮廓路径字标，不依赖设备字体。主页原有PRTS文字及其他布局不变。
