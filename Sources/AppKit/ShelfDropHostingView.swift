import AppKit
import SwiftUI

@MainActor
final class ShelfDropHostingView: NSHostingView<AnyView> {
    weak var store: ShelfStore?

    init(store: ShelfStore) {
        self.store = store
        super.init(
            rootView: AnyView(
                ShelfView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        )
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDropImporter.readableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard store?.isDraggingOut != true else { return [] }
        activateShelfWindow()
        store?.updateDropTargeted(hasFileURLs(sender))
        return store?.isDropTargeted == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard store?.isDraggingOut != true else { return [] }
        let hasFiles = hasFileURLs(sender)
        store?.updateDropTargeted(hasFiles)
        return hasFiles ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !draggingRemainsInsideShelf(sender) else { return }
        store?.updateDropTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        store?.updateDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = FileDropImporter.importFiles(from: sender.draggingPasteboard) { [weak store] urls in
            store?.add(urls: urls)
        }
        store?.updateDropTargeted(false)
        return accepted
    }

    private func activateShelfWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        FileDropImporter.canImport(from: sender.draggingPasteboard)
    }

    /// A child drop destination can disappear when SwiftUI changes the shelf's
    /// drag presentation. That also produces `draggingExited`, even though the
    /// pointer never left the shelf window. Only a physical window exit should
    /// clear the shared targeting state.
    private func draggingRemainsInsideShelf(_ sender: NSDraggingInfo?) -> Bool {
        guard let sender, let contentView = window?.contentView else { return true }
        let point = contentView.convert(sender.draggingLocation, from: nil)
        return contentView.bounds.contains(point)
    }
}
