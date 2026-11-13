import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ShelfStore {
    @ObservationIgnored let diagnosticID = String(UUID().uuidString.prefix(8))

    var items: [ShelfItem] = []
    var selectedIDs: Set<String> = []
    var isExpanded = false
    var isDropTargeted = false
    var targetedDragAction: ShelfAction?
    private(set) var dragActions: [ShelfAction] = []
    @ObservationIgnored private var dragSequence: Int?
    @ObservationIgnored private var dragPasteboardChangeCount: Int?
    @ObservationIgnored private var dragCanImport = false
    var showsDragActions: Bool { isDropTargeted && showQuickActionBar && !isDraggingOut && !dragActions.isEmpty }
    var isFocused = false
    var isKeyboardNavigating = false
    var isHovered = false
    var isClearing = false
    var isDraggingOut = false
    var dismissGestureProgress: CGFloat = 0
    var isDismissGestureActive = false
    var isPullClearing = false
    var isOptionClearActive = false {
        didSet {
            if oldValue != isOptionClearActive { onOptionClearPresentationChanged?() }
        }
    }
    var optionClearProgress: CGFloat = 0
    var keepsEmptyShelfAfterOptionClear = false
    private(set) var isClosed = false

    /// User-facing shelf identity. Empty names fall back to a localised
    /// default so pinned and recent shelves always have a readable title.
    var shelfName = ""
    var tint: ShelfTint = .blue
    var pinnedShelfID: UUID?

    var dragAction: DragDefaultAction = .copy
    var doubleClickAction: FileDoubleClickAction = .open
    var autoCollapseExpanded = true
    var focusShelfOnShow = false
    var instantActionsEnabled = true
    var showQuickActionBar = true
    var enabledActions = ShelfAction.defaultActions
    var customActions: [CustomShelfAction] = []
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @ObservationIgnored var onDropTargetChanged: (() -> Void)?
    @ObservationIgnored var onDropTargetActivityChanged: (() -> Void)?
    @ObservationIgnored private var dropTargetExitTask: Task<Void, Never>?
    @ObservationIgnored var onOptionClearPresentationChanged: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onCollapse: (() -> Void)?
    @ObservationIgnored var onExpansionChanged: ((Bool) -> Void)?
    @ObservationIgnored var onInternalDragEnded: (() -> Void)?
    @ObservationIgnored var onInternalDragStateChanged: ((Bool) -> Void)?
    @ObservationIgnored var onPreviewRequested: ((URL) -> Void)?
    @ObservationIgnored var onDropAccepted: (() -> Void)?
    @ObservationIgnored var onDropFailed: ((String) -> Void)?
    @ObservationIgnored var onDropSettled: (() -> Void)?
    @ObservationIgnored var onEmptied: (() -> Void)?
    @ObservationIgnored var onItemCountChanged: ((Int) -> Void)?
    @ObservationIgnored var onItemsChanged: (() -> Void)?
    @ObservationIgnored var onShelfMetadataChanged: (() -> Void)?
    @ObservationIgnored var onPinRequested: (() -> Void)?

    @ObservationIgnored private var dragReturnedToShelf = false
    @ObservationIgnored private var draggedItemIDs: Set<String> = []
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var pullClearTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    var visibleItems: ArraySlice<ShelfItem> { items.prefix(3) }

    var displayTitle: String {
        let trimmed = shelfName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "文件架" : trimmed
    }

    var compactTitle: String {
        let trimmed = shelfName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? summary : trimmed
    }

    var isPinned: Bool { pinnedShelfID != nil }

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

    func updateExternalDrop(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if dragSequence != sender.draggingSequenceNumber || dragPasteboardChangeCount != pasteboard.changeCount {
            dragSequence = sender.draggingSequenceNumber
            dragPasteboardChangeCount = pasteboard.changeCount
            dragCanImport = FileDropImporter.canImport(from: pasteboard)
            let actions = dragCanImport && !isDraggingOut
                ? Self.actionsForDrag(imagesOnly: FileDropImporter.containsOnlyImages(pasteboard))
                : []
            updateDropTargeted(dragCanImport, actions: actions)
        } else {
            updateDropTargeted(dragCanImport)
        }
        return dragCanImport
    }

    static func actionsForDrag(imagesOnly: Bool) -> [ShelfAction] {
        imagesOnly
            ? [.archive, .compressImages, .resizeImages, .airDrop]
            : [.archive, .airDrop]
    }

    func updateDropTargeted(_ targeted: Bool, actions: [ShelfAction]? = nil) {
        dropTargetExitTask?.cancel()
        dropTargetExitTask = nil
        if !targeted {
            targetedDragAction = nil
            dragSequence = nil
            dragPasteboardChangeCount = nil
        }
        let targetingChanged = isDropTargeted != targeted
        let actionsChanged = actions.map { $0 != dragActions } ?? false
        guard targetingChanged || actionsChanged else { return }
        if let actions, actionsChanged {
            dragActions = actions
            targetedDragAction = nil
        }
        isDropTargeted = targeted
        onDropTargetChanged?()
        guard targetingChanged, !isClosed else { return }
        onDropTargetActivityChanged?()
        if targeted {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func scheduleDropTargetExit() {
        guard isDropTargeted else { return }
        dropTargetExitTask?.cancel()
        dropTargetExitTask = Task { @MainActor [weak self] in
            // A separate native destination receives its enter event after the shelf exits.
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            self?.updateDropTargeted(false)
        }
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
        onItemsChanged?()
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
        onItemsChanged?()
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
        AppDiagnostics.record("shelf-action", category: "Action", fields: ["shelf": diagnosticID, "action": action.rawValue, "selection": String(selectedItems.count)])
        let selected = selectedItems
        let idsByURL = Dictionary(uniqueKeysWithValues: selected.map { ($0.url.standardizedFileURL, $0.id) })
        ShelfActionService.perform(action, urls: selected.map(\.url)) { [weak self] succeeded in
            AppDiagnostics.record("shelf-action-completed", category: "Action", fields: ["shelf": self?.diagnosticID ?? "released", "succeeded": String(succeeded.count)])
            if action == .compressImages || action == .resizeImages {
                self?.add(urls: Array(succeeded))
                return
            }
            guard action == .moveTo || action == .trash else { return }
            self?.remove(items: Set(succeeded.compactMap { idsByURL[$0.standardizedFileURL] }))
        }
    }

    func perform(_ action: CustomShelfAction) {
        AppDiagnostics.record("shelf-custom-action", category: "Action", fields: ["shelf": diagnosticID, "kind": action.kind.rawValue, "selection": String(selectedItems.count)])
        let selected = selectedItems
        let idsByURL = Dictionary(uniqueKeysWithValues: selected.map { ($0.url.standardizedFileURL, $0.id) })
        ShelfActionService.perform(action, urls: selected.map(\.url)) { [weak self] succeeded in
            AppDiagnostics.record("shelf-action-completed", category: "Action", fields: ["shelf": self?.diagnosticID ?? "released", "succeeded": String(succeeded.count)])
            guard action.kind == .moveTo else { return }
            self?.remove(items: Set(succeeded.compactMap { idsByURL[$0.standardizedFileURL] }))
        }
    }

    func remove(items ids: Set<String>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        cancelThumbnailTasks(for: ids)
        items.removeAll { ids.contains($0.id) }
        onItemCountChanged?(items.count)
        onItemsChanged?()
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
        guard !isClosed, !isDraggingOut else { return }
        dragReturnedToShelf = false
        draggedItemIDs = isExpanded ? selectedIDs : Set(items.map(\.id))
        cancelThumbnailTasks(for: draggedItemIDs)
        isDraggingOut = true
        DragDiagnostics.record("drag-began", store: self)
        onInternalDragStateChanged?(true)
    }

    func acceptInternalDragReturn() {
        guard isDraggingOut else { return }
        dragReturnedToShelf = true
    }

    func finishInternalDrag(operation: NSDragOperation, keepOpen: Bool) {
        guard !isClosed, isDraggingOut else { return }
        DragDiagnostics.record("drag-ended", store: self)
        defer { onInternalDragEnded?() }
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
        guard !isClosed else { return }
        isClosed = true
        DragDiagnostics.record("shelf-closed", store: self)
        if isDraggingOut {
            isDraggingOut = false
            draggedItemIDs.removeAll()
            dragReturnedToShelf = false
            onInternalDragStateChanged?(false)
        }
        clearTask?.cancel()
        pullClearTask?.cancel()
        clearTask = nil
        pullClearTask = nil
        cancelThumbnailTasks(for: Set(thumbnailTasks.keys))
        isClearing = false
        updateDropTargeted(false)
        isHovered = false
        isPullClearing = false
        isDismissGestureActive = false
        dismissGestureProgress = 0
        isOptionClearActive = false
        optionClearProgress = 0
    }

    // MARK: - Shelf identity

    func renameShelf(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != shelfName else { return }
        shelfName = trimmed
        onShelfMetadataChanged?()
    }

    func promptRenameShelf() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "重命名文件架"
        alert.informativeText = "名称会显示在文件架和固定列表中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: displayTitle == "文件架" ? "" : displayTitle)
        field.placeholderString = "例如：项目素材"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameShelf(to: field.stringValue)
    }

    func setTint(_ newTint: ShelfTint) {
        guard tint != newTint else { return }
        tint = newTint
        onShelfMetadataChanged?()
    }

    func requestPinToggle() {
        onPinRequested?()
    }

    // MARK: - Item management

    func promptRenameSelected() {
        guard let item = selectedItems.first, selectedItems.count == 1 else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "重命名“\(item.name)”"
        alert.informativeText = "请输入包含扩展名的新名称。原文件会在同一文件夹内重命名。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else { return }
        guard !newName.contains("/") else {
            presentError("名称不能包含斜杠“/”。")
            return
        }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentError("同一文件夹中已存在“\(newName)”。")
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
        } catch {
            presentError(error.localizedDescription)
            return
        }
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let renamed = ShelfItem.make(url: destination) else { return }
        cancelThumbnailTasks(for: [item.id])
        items[index] = renamed
        selectedIDs = [renamed.id]
        loadThumbnails(for: [renamed])
        onItemsChanged?()
    }

    func moveSelectedItems(by offset: Int) {
        guard isExpanded, offset != 0 else { return }
        let selectedIndices = items.indices.filter { selectedIDs.contains(items[$0].id) }
        guard !selectedIndices.isEmpty,
              let first = selectedIndices.first,
              let last = selectedIndices.last,
              selectedIndices.count == last - first + 1 else { return }
        let target: Int
        if offset < 0 {
            target = max(0, first - 1)
            guard target != first else { return }
        } else {
            target = min(items.count, last + 2)
            guard target != last + 1 else { return }
        }
        let block = Array(items[first...last])
        items.removeSubrange(first...last)
        let insertionIndex = offset < 0 ? target : target - block.count
        items.insert(contentsOf: block, at: max(0, min(insertionIndex, items.count)))
        onItemsChanged?()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法完成操作"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
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
                self.onItemsChanged?()
            }
        }
    }

    private func cancelThumbnailTasks(for ids: Set<String>) {
        for id in ids {
            thumbnailTasks.removeValue(forKey: id)?.cancel()
        }
    }
}
