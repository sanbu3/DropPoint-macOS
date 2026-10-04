import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ShelfStore {
    var items: [ShelfItem] = []
    var selectedIDs: Set<String> = []
    var isExpanded = false
    var isDropTargeted = false
    var isFocused = false
    var isHovered = false
    var isClearing = false
    var isDraggingOut = false
    var dismissGestureProgress: CGFloat = 0
    var isDismissGestureActive = false
    var isPullClearing = false
    var isOptionClearActive = false
    var optionClearProgress: CGFloat = 0
    var keepsEmptyShelfAfterOptionClear = false
    private(set) var isClosed = false

    var dragAction: DragDefaultAction = .copy
    var doubleClickAction: FileDoubleClickAction = .open
    var autoCollapseExpanded = true
    var focusShelfOnShow = false
    var instantActionsEnabled = true
    var enabledActions = ShelfAction.defaultActions
    var customActions: [CustomShelfAction] = []
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onCollapse: (() -> Void)?
    @ObservationIgnored var onExpansionChanged: ((Bool) -> Void)?
    @ObservationIgnored var onInternalDragStateChanged: ((Bool) -> Void)?
    @ObservationIgnored var onPreviewRequested: ((URL) -> Void)?
    @ObservationIgnored var onDropAccepted: (() -> Void)?
    @ObservationIgnored var onDropFailed: ((String) -> Void)?
    @ObservationIgnored var onDropSettled: (() -> Void)?
    @ObservationIgnored var onEmptied: (() -> Void)?
    @ObservationIgnored var onItemCountChanged: ((Int) -> Void)?

    @ObservationIgnored private var dragReturnedToShelf = false
    @ObservationIgnored private var draggedItemIDs: Set<String> = []
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var pullClearTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    var visibleItems: ArraySlice<ShelfItem> { items.prefix(3) }

    var selectedItems: [ShelfItem] {
        guard isExpanded else { return items }
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
        guard !isClosed else { return 0 }
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
        keepsEmptyShelfAfterOptionClear = false
        items.append(contentsOf: additions)
        onItemCountChanged?(items.count)
        loadThumbnails(for: additions)
        if selectedIDs.isEmpty, let first = items.first { selectedIDs.insert(first.id) }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        onDropSettled?()
        return additions.count
    }

    func clear() {
        guard !items.isEmpty, !isClearing, !isPullClearing else { return }
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

    func clearKeepingEmptyShelf() {
        guard !items.isEmpty, !isClearing, !isPullClearing else { return }
        keepsEmptyShelfAfterOptionClear = true
        clear()
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

    func moveSelection(by offset: Int) {
        guard isExpanded, !items.isEmpty else { return }
        let currentIndex = items.firstIndex { selectedIDs.contains($0.id) } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), items.count - 1)
        selectedIDs = [items[nextIndex].id]
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
        let idsByURL = Dictionary(uniqueKeysWithValues: selected.map { ($0.url.standardizedFileURL, $0.id) })
        ShelfActionService.perform(action, urls: selected.map(\.url)) { [weak self] succeeded in
            if action == .compressImages {
                self?.add(urls: Array(succeeded))
                return
            }
            guard action == .moveTo || action == .trash else { return }
            self?.remove(items: Set(succeeded.compactMap { idsByURL[$0.standardizedFileURL] }))
        }
    }

    func perform(_ action: CustomShelfAction) {
        let selected = selectedItems
        let idsByURL = Dictionary(uniqueKeysWithValues: selected.map { ($0.url.standardizedFileURL, $0.id) })
        ShelfActionService.perform(action, urls: selected.map(\.url)) { [weak self] succeeded in
            guard action.kind == .moveTo else { return }
            self?.remove(items: Set(succeeded.compactMap { idsByURL[$0.standardizedFileURL] }))
        }
    }

    func remove(items ids: Set<String>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
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
        guard !isDraggingOut else { return }
        dragReturnedToShelf = false
        draggedItemIDs = isExpanded ? selectedIDs : Set(items.map(\.id))
        cancelThumbnailTasks(for: draggedItemIDs)
        isDraggingOut = true
        onInternalDragStateChanged?(true)
    }

    func acceptInternalDragReturn() {
        guard isDraggingOut else { return }
        dragReturnedToShelf = true
    }

    func finishInternalDrag(operation: NSDragOperation, keepOpen: Bool) {
        guard isDraggingOut else { return }
        let draggedIDs = draggedItemIDs
        let moved = operation.contains(.move) && !dragReturnedToShelf
        draggedItemIDs.removeAll()
        isDraggingOut = false
        onInternalDragStateChanged?(false)
        dragReturnedToShelf = false

        if moved, keepOpen {
            let candidates = items.filter { draggedIDs.contains($0.id) }.map(\.url)
            Task { @MainActor [weak self] in
                let missing = await Task.detached(priority: .utility) {
                    Set(candidates.filter { !FileManager.default.fileExists(atPath: $0.path) }.map { $0.standardizedFileURL.path })
                }.value
                guard let self, !self.isClosed else { return }
                self.remove(items: missing)
                self.resumePreviews(for: draggedIDs)
            }
        } else if moved {
            remove(items: draggedIDs)
        } else {
            resumePreviews(for: draggedIDs)
        }
    }

    private func resumePreviews(for ids: Set<String>) {
        loadThumbnails(for: items.filter { ids.contains($0.id) && !$0.isThumbnail })
    }

    func requestClose(commandPressed: Bool) {
        if commandPressed, !items.isEmpty { clear() }
        else { onClose?() }
    }

    func cancelPendingWork() {
        isClosed = true
        clearTask?.cancel()
        pullClearTask?.cancel()
        clearTask = nil
        pullClearTask = nil
        cancelThumbnailTasks(for: Set(thumbnailTasks.keys))
        isClearing = false
        isPullClearing = false
        isDismissGestureActive = false
        dismissGestureProgress = 0
        isOptionClearActive = false
        optionClearProgress = 0
    }

    private func loadThumbnails(for additions: [ShelfItem]) {
        for item in additions {
            let id = item.id
            thumbnailTasks[id]?.cancel()
            thumbnailTasks[id] = Task { @MainActor [weak self] in
                let preview = await ShelfItem.loadPreview(url: item.url)
                guard !Task.isCancelled, let self else { return }
                defer { self.thumbnailTasks[id] = nil }
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                guard let preview else {
                    self.remove(items: [id])
                    if !self.isDraggingOut {
                        self.onDropFailed?("\(item.name)：文件已被移动、删除或暂时无法访问。")
                    }
                    return
                }
                self.items[index] = preview
            }
        }
    }

    private func cancelThumbnailTasks(for ids: Set<String>) {
        for id in ids {
            thumbnailTasks.removeValue(forKey: id)?.cancel()
        }
    }
}
