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

            if store.showQuickActionBar {
                ShelfQuickActionBar(store: store, palette: palette)
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
            }

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
                        .shelfFocusRing(Capsule(), color: palette.accent)
                        .foregroundStyle(palette.accent)
                        .nativeShelfAction(store.selectedIDs.count == store.items.count ? "取消全选" : "全选") {
                            if store.selectedIDs.count == store.items.count { store.selectedIDs.removeAll() }
                            else { store.selectedIDs = Set(store.items.map(\.id)) }
                        }
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
            .optionClearMotion(store, travel: 38)
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
                    .frame(width: 30, height: 30)
                    .background(palette.control, in: Circle())
                    .overlay(Circle().stroke(palette.edge, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .shelfFocusRing(Circle(), color: palette.accent)
            .dropPointHelp("收起文件列表")
            .nativeShelfAction("收起文件列表", action: store.toggleExpanded)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 6, height: 6)
                    Text(store.displayTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .tracking(-0.25)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.promptRenameShelf() }
                        .nativeShelfRename(store.promptRenameShelf)
                        .dropPointHelp("双击重命名文件架")
                    if store.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(palette.accent)
                            .dropPointHelp("已固定")
                    }
                }

                Text(selectionSummary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
                    .contentTransition(.numericText())
                    .animation(
                        reduceMotion ? nil : .snappy(duration: 0.2),
                        value: store.selectedIDs.count
                    )
            }

            Spacer(minLength: 6)

            Menu {
                Button {
                    store.promptRenameShelf()
                } label: {
                    Label("重命名文件架…", systemImage: "pencil")
                }
                Button {
                    store.requestPinToggle()
                } label: {
                    Label(
                        store.isPinned ? "取消固定文件架" : "固定文件架",
                        systemImage: store.isPinned ? "pin.slash" : "pin"
                    )
                }
                Divider()
                Menu("文件架颜色") {
                    ForEach(ShelfTint.allCases) { tint in
                        Button {
                            store.setTint(tint)
                        } label: {
                            HStack {
                                Image(systemName: tint == store.tint ? "checkmark" : "circle.fill")
                                Text(tint.title)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.muted)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .dropPointHelp("文件架设置与操作")
            .nativeShelfMenu("文件架设置与操作") { ShelfContextMenuFactory.make(for: store) }
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

            }
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112)
            .opacity(store.isDraggingOut && selected ? 0 : 1)
        .frame(minHeight: 112, maxHeight: 112)
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .background(NativeHoverRegion(onChange: { hovered = $0 }).allowsHitTesting(false))
        .overlay {
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
        .dropPointHelp(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(selected ? "已选择，\(item.typeLabel)" : item.typeLabel)
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
