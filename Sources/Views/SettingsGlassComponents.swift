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
            .shadow(color: .black.opacity(0.045), radius: 18, y: 8)
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
