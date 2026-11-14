import SwiftUI

struct PermissionGuideView: View {
    let presentation: PermissionGuidePresentation
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PermissionAppIcon(presentation: presentation)
                .frame(width: 52, height: 52)
                .padding(5)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.tint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                .overlay(alignment: .bottomTrailing) {
                    if presentation.hasConfirmedGrant {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                            .font(.system(size: 18)).allowsHitTesting(false)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if presentation.phase == .waiting {
                ProgressView().controlSize(.small).accessibilityLabel("正在检测授权")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .shelfFocusRing(Circle(), color: .accentColor)
            .dropPointHelp("关闭权限提示").accessibilityLabel("关闭权限提示")
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }
    private var title: String {
        switch presentation.phase {
        case .idle: "拖动 DropPoint 图标到输入监控列表"
        case .dragging: "松开图标以添加 DropPoint"
        case .waiting: "请打开 DropPoint 的开关"
        case .retry: "还未检测到权限"
        case .complete: "授权已完成"
        }
    }
    private var detail: String {
        switch presentation.phase {
        case .idle: "添加后开启 DropPoint 开关。列表里已有 DropPoint 时，可直接开启。"
        case .dragging: "添加后打开开关，系统可能要求密码或 Touch ID。"
        case .waiting: "正在检测，完成后自动关闭引导和设置。"
        case .retry: "打开 DropPoint 开关，或将图标重新拖入列表。引导会继续检测。"
        case .complete(let restart): restart ? "权限已记录，重新启动 DropPoint 后生效。" : "现在可以使用晃动与修饰键唤出。"
        }
    }
}
