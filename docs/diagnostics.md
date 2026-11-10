# Debug 与 Release 诊断

基础诊断在两个构建配置中均默认开启，不依赖“额外调试输出”开关。日志位于 `~/Library/Logs/DropPoint/`，也写入 macOS 统一日志。设置 > 通用提供“打开日志”和“导出…”；导出 ZIP 包含运行日志及最多 8 份本应用的系统 IPS 崩溃报告。

每条 JSONL 包含时间戳、系统运行时长、进程 ID、会话 ID、主线程标记、类别、事件与字段。上下文包含版本、build、提交、Debug/Release、系统版本和应用安装路径，用于区分正式安装、开发构建及旧副本。默认不记录文件内容、导入文件的完整路径、粘贴板内容、键盘字符或账户信息。系统生成的 IPS 报告保持原格式，导出后可在发送前自行检查。

当前事件覆盖启动/正常退出、应用激活、输入监控和屏幕录制状态、权限浮窗及拖图标、窗口创建与关闭、拖放会话与导入交付、忽略关闭后的导入、截图失败、快捷键注册状态、文件架操作、诊断导出，以及主队列探测延迟超过 4 秒和恢复。只记录状态转换，不逐帧记录鼠标坐标或每次拖动更新。

日志按进程独立写入串行队列，每个文件约 2 MB，最多保留 12 个文件；自动轮换仅影响本应用日志，不删除系统崩溃报告。退出时等待本应用的日志队列写完。主队列延迟可由锁屏、系统休眠或负载造成，应结合其他事件判断。缺少正常退出记录也不能单独当作崩溃证据。

```bash
python3 scripts/inspect-diagnostics.py --summary
python3 scripts/inspect-diagnostics.py --category Drag --last 100
python3 scripts/inspect-diagnostics.py --category Permission --last 100
python3 scripts/inspect-diagnostics.py --session SESSION_ID --last 200
```

排查时先核对版本、提交和应用路径，再按同一会话及 shelf ID 关联事件。`window-out-completed` 的 `reason` 区分动画回调和有时限的兜底完成。`permission-guide-grant-confirmed` 只在权限服务检测到系统授权记录后产生；拖图标成功不作为授权成功。

Swift 内存访问错误、系统终止等致命情况仍由 macOS 生成崩溃报告；本应用不安装试图从内存错误继续执行的信号处理器。应结合崩溃前日志与系统堆栈诊断。
