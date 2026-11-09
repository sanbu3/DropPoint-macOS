import SwiftUI

/// Horizontal, drop-over-style quick actions for the current selection.
/// The full action list stays available from the context menu; this bar makes
/// the most common actions one click away.
struct ShelfQuickActionBar: View {
    let store: ShelfStore
    let palette: ShelfPalette

    private let preferred: [ShelfAction] = [
        .reveal, .copyPaths, .archive, .compressImages, .createPDF, .airDrop
    ]

    private var visibleActions: [ShelfAction] {
        preferred.filter { store.enabledActions.contains($0) }.prefix(4).map { $0 }
    }

    private var remainingActions: [ShelfAction] {
        store.enabledActions.filter { !visibleActions.contains($0) }
    }

    private var hasSelection: Bool { !store.selectedItems.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(visibleActions) { action in
                        quickButton(action)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !remainingActions.isEmpty || !store.customActions.isEmpty {
                Menu {
                    ForEach(remainingActions) { action in
                        Button {
                            store.perform(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                    if !store.customActions.isEmpty {
                        Divider()
                        ForEach(store.customActions) { action in
                            Button {
                                store.perform(action)
                            } label: {
                                Label(action.name, systemImage: action.kind.systemImage)
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.removeSelected()
                    } label: {
                        Label("从文件架移除", systemImage: "minus.circle")
                    }
                    .disabled(store.selectedItems.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.muted)
                        .frame(width: 28, height: 26)
                        .background(palette.control, in: Capsule())
                        .overlay(Capsule().stroke(palette.edge, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
            }

        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private func quickButton(_ action: ShelfAction) -> some View {
        Button {
            store.perform(action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(shortTitle(action))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(hasSelection ? palette.ink : palette.muted.opacity(0.7))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(palette.control, in: Capsule())
            .overlay(Capsule().stroke(palette.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .shelfFocusRing(Capsule(), color: palette.accent)
        .disabled(!hasSelection)
        .help(action.title)
        .accessibilityLabel(action.title)
    }

    private func shortTitle(_ action: ShelfAction) -> String {
        switch action {
        case .airDrop: "AirDrop"
        case .messages: "信息"
        case .mail: "邮件"
        case .open: "打开"
        case .reveal: "显示"
        case .copyPaths: "复制路径"
        case .compressImages: "压缩"
        case .createPDF: "PDF"
        case .archive: "ZIP"
        case .copyTo: "复制到"
        case .moveTo: "移动到"
        case .trash: "废纸篓"
        }
    }
}
