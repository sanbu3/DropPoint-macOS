# 版本迭代与发布检查

## 版本及兼容性

每次交付修复使用新的补丁版本及递增 build，不覆盖已发布标签。`project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 必须与 `Resources/Info.plist` 一致；修改后运行 `xcodegen generate`。保持应用 bundle ID `io.github.sanbu3.droppoint.macos`、最低 macOS 14 和既有偏好键稳定。

升级保留用户显式设置和固定/最近文件架数据。首次新安装采用默认值；迁移只执行一次。用户仍可将文件架主快捷键切回显示/隐藏。固定/最近记录保存路径，源文件被移走后需重新指定。

## 验证和构建

```bash
python3 scripts/verify-release.py
xcodebuild -project DropPointNative.xcodeproj -scheme DropPointNative \
  -configuration Debug -derivedDataPath .build/Debug test
xcodebuild -project DropPointNative.xcodeproj -scheme DropPointNative \
  -configuration Release -derivedDataPath .build/Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

有新功能或修复时先验证相应回归，再跑全量。2026-11-10 的 2.0.2 结果为 102 项，101 通过、1 项跳过、0 失败。被跳过的是没有系统授权时的真实窗口连续截图测试，不能把跳过记作通过。构建覆盖 arm64 与 x86_64；本机执行测试仅覆盖当前架构和系统。

## 绑定源码和安装包

先提交经过测试的应用源码，再给构建产物写入对应提交及源码指纹，然后签名。不要在写入指纹后修改应用输入或资源。

```bash
python3 scripts/verify-release.py --stamp .build/Release/Build/Products/Release/DropPoint.app
codesign --force --deep --sign - .build/Release/Build/Products/Release/DropPoint.app
codesign --verify --deep --strict .build/Release/Build/Products/Release/DropPoint.app
```

安装前备份旧应用到构建目录，退出旧进程，在暂存位置校验新版签名后再替换 `/Applications/DropPoint.app`。安装后比较整个应用内容，并核对实际运行的可执行文件路径，防止启动另一份旧构建。

```bash
python3 scripts/verify-release.py --app /Applications/DropPoint.app \
  --reference .build/Release/Build/Products/Release/DropPoint.app
```

当前使用本地 ad-hoc 签名，没有 Developer ID 公证。升级后 macOS 可能要求重新确认输入监控或屏幕录制权限；更改版本不能代替系统授权。日后正式分发可使用稳定的 Developer ID 身份和公证流程，不关闭 Gatekeeper。

推送使用普通 fast-forward 更新，保留历史；先确认云端主分支没有新提交。版本标签应指向同一已验证提交，不强制改写旧标签。发布二进制发行包是独立动作，代码推送本身不会更新 GitHub Releases 下载资产。

## 尚需实机验证

- 系统授权后的实际连续截图及授权撤销/重新授予。
- Finder、浏览器、Codex 等来源的真实拖入/拖出及拖放中关闭。
- 物理键盘左右 Command、全局晃动和修饰键唤出。
- 多显示器布局、设置窗口移动、浅/深桌面材质和 macOS 14 等旧系统。

自动化覆盖应用自身的生命周期、导入、帧时长、命中检测、文件不覆盖和设置迁移，不宣称所有第三方服务与硬件组合均已无缺陷。
