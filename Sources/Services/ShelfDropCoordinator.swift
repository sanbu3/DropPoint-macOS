import AppKit

/// A shelf owns import delivery. Native views can be replaced by SwiftUI at
/// any point, so neither the destination view nor its callbacks own the work.
@MainActor
enum ShelfDropCoordinator {
    @discardableResult
    static func accept(
        _ pasteboard: NSPasteboard, into store: ShelfStore, action: ShelfAction? = nil
    ) -> Bool {
        guard !store.isClosed else {
            AppDiagnostics.record("import-rejected-closed", category: "Import", fields: ["shelf": store.diagnosticID])
            return false
        }
        let shelfID = store.diagnosticID
        let accepted = FileDropImporter.importFiles(from: pasteboard) { [weak store] event in
            guard let store, !store.isClosed else {
                AppDiagnostics.record("import-result-ignored-closed", category: "Import", fields: ["shelf": shelfID])
                return
            }
            switch event {
            case .imported(let urls):
                DragDiagnostics.record("import-delivered", store: store)
                if let action {
                    AppDiagnostics.record("drop-action", category: "Action", fields: ["shelf": shelfID, "action": action.rawValue])
                    NSApp.activate()
                    ShelfActionService.perform(action, urls: urls) { [weak store] outputs in
                        if action == .compressImages || action == .resizeImages {
                            store?.add(urls: Array(outputs))
                        }
                    }
                } else {
                    store.add(urls: urls)
                }
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
