import AppKit
import SwiftUI

extension Color {
    static let dropPointBlue = Color(red: 0.10, green: 0.49, blue: 0.98)
}

struct DropPointGlassBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RadialGradient(
                colors: [Color.dropPointBlue.opacity(0.13), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 620
            )
            LinearGradient(
                colors: [Color.white.opacity(0.04), .clear, Color.black.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct DropPointSettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

struct DropPointPermissionBadge: View {
    let state: SystemPermissionState
    let permissionName: String
    var showsPermissionName = false

    private var status: (text: String, icon: String, tint: Color) {
        switch state {
        case .active: ("已授权", "checkmark.circle.fill", .green)
        case .notGranted: ("未授权", "lock.circle.fill", .orange)
        case .requiresRelaunch: ("待重启", "arrow.clockwise.circle.fill", .orange)
        }
    }

    var body: some View {
        let status = status
        HStack(spacing: 5) {
            Image(systemName: status.icon)
                .foregroundStyle(status.tint)
            Text(showsPermissionName ? "\(permissionName) · \(status.text)" : status.text)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.13), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(permissionName) \(status.text)")
    }
}

struct DropPointLogoImage: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "DropPointLogo", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "shippingbox.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.dropPointBlue)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DropPointSettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.remove([.titled, .closable, .miniaturizable])
        window.styleMask.insert(.resizable)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
