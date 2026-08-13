import AppKit
import SwiftUI

struct ExpandedShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ShelfStore
    let palette: ShelfPalette

    private let columns = [
        GridItem(.adaptive(minimum: 116, maximum: 124), spacing: 8, alignment: .top)
    ]

    private var pullProgress: CGFloat {
        min(max(store.dismissGestureProgress, 0), 1)
    }

    private var fadeProgress: CGFloat {
        min(max((pullProgress - 0.66) / 0.34, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            ExpandedShelfHeader(store: store, palette: palette)

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("文件")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(palette.fileType)

                    Text("\(store.items.count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(palette.control, in: Capsule())

                    Spacer()

                    if store.items.count >= 2 {
                        Button {
                            if store.selectedIDs.count == store.items.count {
                                store.selectedIDs.removeAll()
                            } else {
                                store.selectedIDs = Set(store.items.map(\.id))
                            }
                        } label: {
                            Text(store.selectedIDs.count == store.items.count ? "取消全选" : "全选")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .foregroundStyle(palette.accent)
                    }
                }
                .frame(height: 17)

                if store.items.count > 4 {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(store.items) { item in
                                ExpandedFileTile(item: item, store: store, palette: palette)
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(store.items) { item in
                            ExpandedFileTile(item: item, store: store, palette: palette)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .offset(y: 74 * pullProgress)
            .scaleEffect(1 - 0.1 * fadeProgress, anchor: .bottom)
            .opacity(1 - fadeProgress)
            .allowsHitTesting(!store.isDismissGestureActive && !store.isPullClearing)
            .animation(
                reduceMotion || store.isDismissGestureActive
                    ? nil
                    : .smooth(duration: 0.18),
                value: pullProgress
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.ink)
    }
}

private struct ExpandedShelfHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ShelfStore
    let palette: ShelfPalette

    var body: some View {
        HStack(spacing: 10) {
            Button(action: store.toggleExpanded) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(palette.control, in: Circle())
                    .overlay(Circle().stroke(palette.edge, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("收起文件列表")

            VStack(alignment: .leading, spacing: 1) {
                Text("文件架")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(-0.25)

                Text(selectionSummary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .contentTransition(.numericText())
                    .animation(
                        reduceMotion ? nil : .snappy(duration: 0.2),
                        value: store.selectedIDs.count
                    )
            }

            Spacer(minLength: 8)

            if !store.selectedIDs.isEmpty {
                HStack(spacing: 4) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            store.selectedItems.map(\.url)
                        )
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 9, weight: .semibold))
                            Text("在 Finder 中显示")
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(palette.accentSurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("在 Finder 中显示选中的文件")

                    Button {
                        store.removeSelected()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 9, weight: .semibold))
                            Text("移除")
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.danger)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(palette.danger.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("从文件架中移除选中的文件")
                }
            }
        }
        .frame(height: 52)
        .padding(.leading, 16)
        .padding(.trailing, 44)
    }

    private var selectionSummary: String {
        guard !store.selectedIDs.isEmpty else { return "\(store.items.count) 个文件 · 未选择" }
        return "\(store.items.count) 个文件 · 已选 \(store.selectedIDs.count) 个"
    }
}

private struct ExpandedFileTile: View {
    let item: ShelfItem
    let store: ShelfStore
    let palette: ShelfPalette

    @State private var hovered = false

    private var selected: Bool { store.selectedIDs.contains(item.id) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tileBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                selected ? palette.accentEdge : palette.edge.opacity(hovered ? 0.8 : 0),
                                lineWidth: 1
                            )
                    }

                VStack(spacing: 5) {
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: item.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                            .clipShape(.rect(cornerRadius: item.isThumbnail ? 7 : 0))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1.5)

                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(palette.accent, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                                .offset(x: 6, y: -4)
                        }
                    }
                    .frame(height: 51)

                    Text(item.name)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 27, alignment: .top)

                    Text(item.typeLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.35)
                        .foregroundStyle(selected ? palette.accent : palette.fileType)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.top, 9)
                .padding(.bottom, 7)

                FileDragOutOverlay(
                    store: store,
                    itemsProvider: { store.selectedItems },
                    dragAction: store.dragAction,
                    onClick: selectItem,
                    onDoubleClick: { store.performDoubleClick(on: item) },
                    onDragBegan: store.beginInternalDrag,
                    onDragEnded: store.finishInternalDrag,
                    contextMenuProvider: {
                        store.select(item, extending: false)
                        return ShelfContextMenuFactory.make(for: store)
                    }
                )
            }
            .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104)

            Capsule()
                .fill(selected ? palette.accent : .clear)
                .frame(width: 38, height: 4)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 112, maxHeight: 112)
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .onHover { hovered = $0 }
        .contextMenu { tileContextMenu }
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(selected ? "已选择，\(item.typeLabel)" : item.typeLabel)
    }

    @ViewBuilder
    private var tileContextMenu: some View {
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Button("拷贝路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
        Divider()
        Button("从文件架移除") {
            store.remove(items: [item.id])
        }
    }

    private var tileBackground: Color {
        if selected { return palette.accentSurface }
        if hovered { return palette.control.opacity(0.72) }
        return .clear
    }

    private func selectItem(modifiers: NSEvent.ModifierFlags) {
        store.select(
            item,
            extending: modifiers.contains(.command) || modifiers.contains(.control),
            range: modifiers.contains(.shift)
        )
    }
}
