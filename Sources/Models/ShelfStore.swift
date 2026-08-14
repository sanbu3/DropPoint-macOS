import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ShelfStore {
    var items: [ShelfItem] = []
    var selectedIDs: Set<String> = []
    var presentation: ShelfPresentation
    var isExpanded = false
    var isDropTargeted = false
    var isFocused = false
    var isClearing = false
    var isDraggingOut = false
    var dismissGestureProgress: CGFloat = 0
    var isDismissGestureActive = false
    var isPullClearing = false

    @ObservationIgnored var dragAction: DragDefaultAction = .copy
    @ObservationIgnored var doubleClickAction: FileDoubleClickAction = .open
    @ObservationIgnored var autoCollapseExpanded = true
    @ObservationIgnored var focusShelfOnShow = false
    @ObservationIgnored var instantActionsEnabled = true
    @ObservationIgnored var enabledActions = ShelfAction.defaultActions
    @ObservationIgnored var customActions: [CustomShelfAction] = []
    @ObservationIgnored var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onCollapse: (() -> Void)?
    @ObservationIgnored var onExpansionChanged: ((Bool) -> Void)?
    @ObservationIgnored var onQuickCommit: (() -> Void)?
    @ObservationIgnored var onInternalDragStateChanged: ((Bool) -> Void)?
    @ObservationIgnored var onPreviewRequested: ((URL) -> Void)?
    @ObservationIgnored var onDropAccepted: (() -> Void)?
    @ObservationIgnored var onDropSettled: (() -> Void)?
    @ObservationIgnored var onEmptied: (() -> Void)?
    @ObservationIgnored var onItemCountChanged: ((Int) -> Void)?

    @ObservationIgnored private var dragReturnedToShelf = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var pullClearTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    init(presentation: ShelfPresentation = .standard) {
        self.presentation = presentation
    }

    var visibleItems: ArraySlice<ShelfItem> { items.prefix(3) }

    var selectedItems: [ShelfItem] {
        guard isExpanded, !selectedIDs.isEmpty else { return items }
        return items.filter { selectedIDs.contains($0.id) }
    }

    var summary: String {
        items.count == 1 ? items[0].name : "\(items.count) 项"
    }

    var expandedTitle: String {
        selectedIDs.count > 1
            ? "已选 \(selectedIDs.count) / \(items.count) 项"
            : "\(items.count) 项"
    }

    func updateDropTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else { return }
        isDropTargeted = targeted
        guard targeted else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    @discardableResult
    func add(urls: [URL]) -> Int {
        let existing = Set(items.map(\.id))
        var seen = existing
        var additions: [ShelfItem] = []
        var duplicateCount = 0

        for url in urls {
            let identifier = url.standardizedFileURL.path
            if seen.contains(identifier) {
                duplicateCount += 1
                continue
            }
            guard let item = ShelfItem.make(url: url) else { continue }
            seen.insert(identifier)
            additions.append(item)
        }

        if isDraggingOut, additions.isEmpty, duplicateCount == urls.count, !urls.isEmpty {
            dragReturnedToShelf = true
        }

        guard !additions.isEmpty else { return 0 }
        let wasEmpty = items.isEmpty
        items.append(contentsOf: additions)
        onItemCountChanged?(items.count)
        loadThumbnails(for: additions)
        if selectedIDs.isEmpty, let first = items.first { selectedIDs.insert(first.id) }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if wasEmpty, presentation == .tray { onQuickCommit?() }
        onDropSettled?()
        return additions.count
    }

    func clear() {
        guard !items.isEmpty, !isClearing else { return }
        let itemIDs = Set(items.map(\.id))
        isClearing = true

        if reduceMotion {
            finishClear(itemIDs: itemIDs)
            return
        }

        clearTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(240))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.finishClear(itemIDs: itemIDs)
        }
    }

    func clearFromPullGesture() {
        guard !items.isEmpty, !isClearing, !isPullClearing else { return }
        let itemIDs = Set(items.map(\.id))
        isPullClearing = true
        isDismissGestureActive = false

        if reduceMotion {
            finishClear(itemIDs: itemIDs)
            return
        }

        pullClearTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(110))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.finishClear(itemIDs: itemIDs)
        }
    }

    private func finishClear(itemIDs: Set<String>) {
        isExpanded = false
        onExpansionChanged?(false)
        cancelThumbnailTasks(for: itemIDs)
        items.removeAll { itemIDs.contains($0.id) }
        onItemCountChanged?(items.count)
        selectedIDs.subtract(itemIDs)
        if selectedIDs.isEmpty, let first = items.first {
            selectedIDs.insert(first.id)
        }
        isClearing = false
        isPullClearing = false
        isDismissGestureActive = false
        dismissGestureProgress = 0
        clearTask = nil
        pullClearTask = nil
        if items.isEmpty { onEmptied?() }
    }

    func toggleExpanded() {
        guard items.count > 1 else { return }
        isExpanded.toggle()
        if isExpanded {
            selectedIDs = Set(items.first.map { [$0.id] } ?? [])
        } else {
            selectedIDs.removeAll()
        }
        onExpansionChanged?(isExpanded)
    }

    func select(_ item: ShelfItem, extending: Bool, range: Bool = false) {
        if range, let lastSelected = items.first(where: { selectedIDs.contains($0.id) }),
           let lastIdx = items.firstIndex(of: lastSelected),
           let thisIdx = items.firstIndex(of: item) {
            let range = lastIdx < thisIdx ? lastIdx...thisIdx : thisIdx...lastIdx
            selectedIDs = Set(items[range].map(\.id))
        } else if extending {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        } else {
            selectedIDs = [item.id]
        }
    }

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
    }

    func copySelectedToClipboard() {
        let urls: [URL]
        if isExpanded, !selectedIDs.isEmpty {
            urls = selectedItems.map(\.url)
        } else {
            urls = items.map(\.url)
        }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    @discardableResult
    func previewSelection() -> Bool {
        let url: URL?
        if items.count == 1 {
            url = items.first?.url
        } else if isExpanded {
            url = items.first { selectedIDs.contains($0.id) }?.url
        } else {
            url = nil
        }
        guard let url else { return false }
        onPreviewRequested?(url)
        return true
    }

    func performDoubleClick(on item: ShelfItem? = nil) {
        let urls = item.map { [$0.url] } ?? selectedItems.map(\.url)
        switch doubleClickAction {
        case .open:
            ShelfActionService.perform(.open, urls: urls)
        case .reveal:
            ShelfActionService.perform(.reveal, urls: urls)
        case .none:
            break
        }
    }

    func perform(_ action: ShelfAction) {
        let selected = selectedItems
        let ids = Set(selected.map(\.id))
        ShelfActionService.perform(action, urls: selected.map(\.url)) { [weak self] succeeded in
            guard succeeded, action == .moveTo || action == .trash else { return }
            self?.remove(items: ids)
        }
    }

    func perform(_ action: CustomShelfAction) {
        let selected = selectedItems
        let ids = Set(selected.map(\.id))
        ShelfActionService.perform(action, urls: selected.map(\.url)) { [weak self] succeeded in
            guard succeeded, action.kind == .moveTo else { return }
            self?.remove(items: ids)
        }
    }

    func remove(items ids: Set<String>) {
        cancelThumbnailTasks(for: ids)
        items.removeAll { ids.contains($0.id) }
        onItemCountChanged?(items.count)
        selectedIDs.subtract(ids)
        if items.count <= 1, isExpanded {
            isExpanded = false
            onExpansionChanged?(false)
        }
        if items.isEmpty {
            onEmptied?()
        }
    }

    func removeSelected() {
        remove(items: selectedIDs)
    }

    func beginInternalDrag() {
        dragReturnedToShelf = false
        isDraggingOut = true
        onInternalDragStateChanged?(true)
    }

    func finishInternalDrag(succeeded: Bool, keepOpen: Bool) {
        isDraggingOut = false
        onInternalDragStateChanged?(false)
        if succeeded, !keepOpen, !dragReturnedToShelf {
            if isExpanded {
                items.removeAll { selectedIDs.contains($0.id) }
                onItemCountChanged?(items.count)
                selectedIDs.removeAll()
                if items.count <= 1 {
                    isExpanded = false
                    onExpansionChanged?(false)
                }
                if items.isEmpty {
                    onEmptied?()
                }
            } else {
                clear()
            }
        }
        dragReturnedToShelf = false
    }

    func requestClose(commandPressed: Bool) {
        if commandPressed, !items.isEmpty { clear() }
        else { onClose?() }
    }

    private func loadThumbnails(for additions: [ShelfItem]) {
        for item in additions {
            let id = item.id
            thumbnailTasks[id]?.cancel()
            thumbnailTasks[id] = Task { @MainActor [weak self] in
                let image = await ShelfItem.thumbnail(url: item.url)
                guard !Task.isCancelled, let self else { return }
                defer { self.thumbnailTasks[id] = nil }
                guard let image,
                      let index = self.items.firstIndex(where: { $0.id == id }) else {
                    return
                }
                self.items[index] = self.items[index].replacingImage(
                    image,
                    isThumbnail: true
                )
            }
        }
    }

    private func cancelThumbnailTasks(for ids: Set<String>) {
        for id in ids {
            thumbnailTasks.removeValue(forKey: id)?.cancel()
        }
    }
}
