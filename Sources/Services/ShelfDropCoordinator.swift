import AppKit

/// A shelf owns import delivery. Native views can be replaced by SwiftUI at
/// any point, so neither the destination view nor its callbacks own the work.
@MainActor
enum ShelfDropCoordinator {
    @discardableResult
    static func accept(_ pasteboard: NSPasteboard, into store: ShelfStore) -> Bool {
        guard !store.isClosed else { return false }
        let accepted = FileDropImporter.importFiles(from: pasteboard) { [weak store] event in
            guard let store, !store.isClosed else { return }
            switch event {
            case .imported(let urls):
                DragDiagnostics.record("import-delivered", store: store)
                store.add(urls: urls)
            case .failed(let message):
                DragDiagnostics.record("import-failed", store: store)
                store.onDropFailed?(message)
            }
        }
        if accepted {
            DragDiagnostics.record("drop-accepted", store: store)
            store.onDropAccepted?()
        }
        store.updateDropTargeted(false)
        return accepted
    }
}
