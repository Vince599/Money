# App 图标 · 有度

设计日期：2026-09-26。图标概念名为「有度」，App 显示名称仍为 Ledger。

按「背景不能是黑色」的反馈，当前方案改为纯色浅暖象牙白底（约 `#F3F0E8`），搭配带暖调的中深石墨色陶瓷开环与独立圆点。保留原有形状与构图，表达积累、流动与留白：管理财富，也为生活保留余地。没有文字或货币符号；以粗轮廓和明暗对比保留小尺寸辨识度。

## 文件与接入

- [生产图标](../../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png)：1024 × 1024、24 位 RGB、不含透明通道的 PNG。
- [当前生成原图](source-light.png)：1254 × 1254 RGB，保留内置 imagegen 编辑后的原始输出。
- [当前编辑提示词](prompt-light.txt)：使用内置 `image_gen` 编辑，没有使用 CLI/API 回退。
- [初版原图](source.png)与[初版提示词](prompt.txt)：作为历史设计保留，不是当前使用的版本。
- [资源配置](../../App/Assets.xcassets/AppIcon.appiconset/Contents.json)：iOS universal 单尺寸图标。
- `project.yml` 的 Ledger 应用目标已设置 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`。

使用内置 imagegen 调整背景与主体颜色；打包时仅通过 Windows System.Drawing 高质量双三次缩放，以确定性处理得到 1024 × 1024 生产尺寸。图像为完整正方形，圆角由系统施加。现有构建入口会自动包含 App 下的资源目录。

## 验证状态

当前浅色版本已检查资源 JSON 与文件引用、1024 × 1024 生产尺寸、24 位 RGB 无透明通道、四角与环内中心的浅色背景，以及差异格式。已目视检查编辑原图和 60 × 60 缩略图，开环与独立圆点保持可辨识。目标构建设置沿用已接入的 AppIcon。

尚未通过 Apple `actool` 编译或在已安装的 iPhone App 上检查。本次是静态图标资源与工程配置接入，不是新的 IPA 构建；未制作 Icon Composer 分层文件或单独的深色／着色版本。

规格参考：[Apple 资源目录图标配置](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)、[Apple 图标设计指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。
