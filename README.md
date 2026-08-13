# DropPoint Native

DropPoint 的原生 macOS SwiftUI 版本。它提供一个轻量文件架，让文件、文件夹和图片可以暂存、预览，再拖到目标位置。

## 已实现

- 198×207 紧凑 Shelf 与 432×390 多文件展开态
- 文件/文件夹拖入、去重、原生图标与图片缩略图
- 多文件拖出、Shift 拖出后保留、⌘ 点击清空
- 单文件及展开文件架选中项的空格快速预览
- 多选文件、移除项目与在 Finder 中显示
- 菜单栏常驻、快速 Shelf、拖动摇一摇新建
- 每次新的文件拖拽均可重新通过摇晃生成文件架
- 多窗口级联、自动贴边与流畅的窗口移动动画
- 触控板双指下滑清空：文件跟随手势移动，越过阈值后触觉反馈
- Shift+Tab 与 Option+Shift+A 全局快捷键
- 从剪贴板路径、文本或图片创建 Shelf
- 独立的桌面目录与截图文件监听，避免内部拖出造成重复文件架
- 原生设置窗口、深色模式与偏好持久化

## 构建

直接用 Xcode 打开 `DropPointNative.xcodeproj`，选择 `DropPointNative` scheme 运行。

也可以使用命令行：

```bash
xcodegen generate
xcodebuild \
  -project DropPointNative.xcodeproj \
  -scheme DropPointNative \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  build
```

构建产物位于：

```text
.build/DerivedData/Build/Products/Release/DropPoint.app
```

全局 Finder 拖动监测需要在 macOS 提示时允许输入监控权限；普通窗口内拖放不依赖该权限。
