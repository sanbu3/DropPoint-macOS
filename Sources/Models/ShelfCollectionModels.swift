import Foundation

/// A shelf the user explicitly kept. Pinned shelves survive relaunches and
/// can be reopened from the DropPoint window, the menu bar and the context
/// menu. Items are stored as paths, matching the shelf's reference-only model.
struct PinnedShelf: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var tint: ShelfTint
    var paths: [String]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        tint: ShelfTint = .blue,
        paths: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.tint = tint
        self.paths = paths
        self.createdAt = createdAt
    }

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    var itemCount: Int { paths.count }
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "固定文件架" : trimmed
    }
}

/// Snapshot of a closed shelf. Kept in memory on disk so the last ten shelves
/// can be reopened after quitting DropPoint.
struct RecentShelf: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var tint: ShelfTint
    var paths: [String]
    var closedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        tint: ShelfTint = .blue,
        paths: [String],
        closedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.tint = tint
        self.paths = paths
        self.closedAt = closedAt
    }

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    var itemCount: Int { paths.count }
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "文件架" : trimmed
    }

    var subtitle: String {
        itemCount == 1 ? "1 项" : "\(itemCount) 项"
    }
}
