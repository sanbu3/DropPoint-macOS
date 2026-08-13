<div align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/appicon_128.png" width="96" height="96" alt="DropPoint app icon">
  <h1>DropPoint for macOS</h1>
  <p>一个用 SwiftUI 与 AppKit 重写的原生 macOS 临时文件架。</p>
</div>

> [!IMPORTANT]
> 本仓库只包含 macOS 原生实现，不包含 Electron、Node.js、网页前端或跨平台运行时。

DropPoint 可以在跨窗口、跨桌面拖放文件时充当临时中转站：把文件放进文件架，切换到目标位置，再拖出来即可。应用在本机处理文件，不建立账户，也不把文件上传到自有服务器。

## 功能

- 原生 SwiftUI / AppKit 窗口、菜单栏与拖放体验
- 单文件紧凑文件架和多文件展开文件架
- 文件、文件夹及图片暂存，原生图标与图片缩略图
- 选中项目后按空格调用 macOS Quick Look 预览
- 多选、移除、在 Finder 中显示及系统分享操作
- 摇晃拖拽、全局快捷键、剪贴板内容快速创建文件架
- 文件放入后的窗口贴边移动与多窗口级联
- 拖入区域触觉反馈；离开后再次进入可再次触发
- 触控板双指下滑清空，文件图标与手柄随手势反馈
- 监听指定文件夹，并独立识别桌面截图
- 区分应用内部拖出与外部新增，避免重复生成文件架
- `⌘W` 关闭当前文件架，`⇧⌘T` 恢复最近关闭的内容
- 深色模式、原生设置窗口与偏好持久化

## 系统要求

- macOS 14 Sonoma 或更高版本
- Apple silicon 或 Intel 64 位 Mac（Release DMG 为 Universal 构建）

## 安装

1. 前往 [Releases](https://github.com/sanbu3/DropPoint-macOS/releases) 下载最新 DMG。
2. 打开 DMG，把 `DropPoint.app` 拖到“应用程序”。
3. 首次启动时，如 macOS 提示来源未验证，请在 Finder 中右键应用并选择“打开”。不要关闭 Gatekeeper。

当前公开构建使用本地签名，尚未使用 Apple Developer ID 公证。请只从本仓库的 Release 页面下载，并按需核对 Release 中公布的 SHA-256。

## 基本使用

1. 从 Finder 或其他应用开始拖动文件。
2. 将文件放入出现的 DropPoint 文件架。
3. 切换到目标窗口或桌面，再从文件架拖出。

常用操作：

| 操作 | 结果 |
| --- | --- |
| `⇧Tab` | 新建或显示文件架（取决于设置） |
| `⌥⇧A` | 从剪贴板创建文件架 |
| `Space` | 预览单文件或展开状态下的选中项目 |
| `⌘W` | 关闭当前文件架 |
| `⇧⌘T` | 恢复最近关闭的内容 |
| 双指下滑 | 越过阈值后清空当前文件架 |

## 权限与隐私

- “输入监控”只用于识别 Finder 中的全局文件拖动与摇晃手势；普通窗口内拖放不依赖该权限。
- 文件夹和桌面截图监听只观察用户启用的本地目录。系统要求时，需要授予对应目录的访问权限。
- 文件处理、缩略图、预览和目录监听均在本机完成。
- AirDrop、信息和邮件由 macOS 系统分享服务处理。

## 从源码构建

需要 Xcode 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。本项目不需要 Node.js、npm 或 Electron。

```bash
git clone https://github.com/sanbu3/DropPoint-macOS.git
cd DropPoint-macOS
xcodegen generate
xcodebuild \
  -project DropPointNative.xcodeproj \
  -scheme DropPointNative \
  -configuration Release \
  -derivedDataPath .build/Release \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build
```

构建产物位于：

```text
.build/Release/Build/Products/Release/DropPoint.app
```

## 项目结构

```text
Sources/
├── App/          # 应用生命周期
├── AppKit/       # 原生窗口、拖放与菜单桥接
├── Models/       # 文件架状态、设置与项目元数据
├── Services/     # 快捷键、监听、导入和窗口管理
├── Utilities/    # 几何与视觉辅助
└── Views/        # SwiftUI 文件架和设置界面
Resources/        # 图标、SVG 与 Info.plist
Tests/            # 纯逻辑单元测试
```

## 作者与致谢

本原生 macOS 版本由 **王汪旺**（[@sanbu3](https://github.com/sanbu3)）维护，源码位于 [sanbu3/DropPoint-macOS](https://github.com/sanbu3/DropPoint-macOS)。

核心产品灵感来自 Sudev Suresh Sreedevi（[@GameGodS3](https://github.com/GameGodS3)）创建的 [DropPoint](https://github.com/GameGodS3/DropPoint)，谨此致谢。本仓库是使用 SwiftUI 与 AppKit 完成的独立原生实现。

## 开源许可

本项目按 [GNU General Public License v3.0](LICENSE) 发布。你可以在该许可证允许的范围内使用、研究、修改和再分发源码；分发修改版或二进制时，须同时履行 GPLv3 对对应源码、许可证文本、版权及修改说明的要求。

本软件按“原样”提供，不附带任何明示或暗示担保。完整条款以 `LICENSE` 为准。

## 贡献

欢迎提交 Issue 或 Pull Request。提交前请确保：

- 修改仅面向原生 macOS 工程，不引入 Electron 或 Node.js 运行时；
- 能通过 Release 配置编译；
- 涉及交互时同时考虑键盘、辅助功能与“减少动态效果”；
- 保留 `LICENSE` 及必要的来源说明。
