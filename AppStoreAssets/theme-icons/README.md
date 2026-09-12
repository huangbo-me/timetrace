# 主题桌面图标

暖砂保留原始 `AppIcon`；森林、晴空、暮紫、蔷薇使用四套备用资源，位于 `TimeTrace/Assets.xcassets/AppIcon{Sage,Sky,Lavender,Rose}.appiconset/`。

使用内置 imagegen 编辑原始 `AppIcon.appiconset/AppIcon-1024.png`，保留时钟、定位标记、轨迹、勾选图案及白底。生成结果经尺寸标准化后以 1024×1024、不带 Alpha 的 PNG 打包；不覆盖原始主图标。

## 生成提示词

每套图标单独调用内置工具，使用以下提示词，替换颜色及主题名：

> Create a single 1024x1024 iOS app icon color variant of this exact reference. Preserve the complete clock/location-pin/curved route/checkmark design, geometry, alignment, scale, white background and soft depth. Change ONLY the golden brown mark and route to {color}. Keep dark dots and check circle dark neutral coordinated with the theme. No text, no rounded outside corners, no border, opaque full square white background. This is the {name} theme asset. Save output image.

| name | color |
| --- | --- |
| Sage | forest green #356448 |
| Sky | sky blue #365F87 |
| Lavender | muted lavender purple #70518B |
| Rose | rose pink #89475D |

## 接入方式

设置页提供“桌面图标跟随主题”开关，默认关闭。开启时立即同步当前主题的图标，之后点选主题会应用界面配色并请求 UIKit 更换备用图标。关闭时保留当前图标，切换主题只影响 App 内外观。系统会显示更换提示；失败时保留界面主题，提供重试。重复选择当前图标不请求更换，切回暖砂使用主图标。浅色/深色显示模式不触发图标切换。
