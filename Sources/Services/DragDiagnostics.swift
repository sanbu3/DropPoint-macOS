import OSLog

/// Local lifecycle breadcrumbs; never includes file paths or pasteboard data.
@MainActor
enum DragDiagnostics {
    private static let logger = Logger(subsystem: "io.github.sanbu3.droppoint.macos", category: "DragLifecycle")

    static func record(_ event: String, store: ShelfStore) {
        AppDiagnostics.record(event, category: "Drag", fields: ["shelf": store.diagnosticID, "items": String(store.items.count), "dragging": String(store.isDraggingOut)])
        logger.notice("\(event, privacy: .public) shelf=\(store.diagnosticID, privacy: .public) items=\(store.items.count) dragging=\(store.isDraggingOut)")
    }
}
