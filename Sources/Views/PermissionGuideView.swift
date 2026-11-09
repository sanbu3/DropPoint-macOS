import SwiftUI

struct PermissionGuideView: View {
    let permission: InputMonitoringPermissionService
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PermissionAppIcon().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if permission.state == .requiresRelaunch {
                    Button("重新启动 DropPoint", action: permission.relaunch)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .shelfFocusRing(Capsule(), color: .accentColor)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .shelfFocusRing(Circle(), color: .accentColor)
            .help("关闭权限提示")
            .accessibilityLabel("关闭权限提示")
        }
        .padding(16)
        .frame(width: 340, height: 112)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
    }

    private var title: String {
        switch permission.state {
        case .notGranted: "将图标拖入输入监控列表"
        case .requiresRelaunch: "已授权，重启后生效"
        case .active: "已可以识别拖动"
        }
    }
    private var detail: String {
        switch permission.state {
        case .notGranted: "再打开 DropPoint 的开关。\n已有应用直接开启，也可点“+”添加。"
        case .requiresRelaunch: "重新启动后即可使用晃动唤出。"
        case .active: "拖动文件时，晃动鼠标即可唤出。"
        }
    }
}
