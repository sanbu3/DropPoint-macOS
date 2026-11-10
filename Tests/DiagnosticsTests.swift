import Foundation
import XCTest
@testable import DropPoint

final class DiagnosticsTests: XCTestCase {
    func testConcurrentDiagnosticEventsRemainSeparateValidJSONLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DiagnosticLogWriter(directory: directory)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            var data = try! JSONSerialization.data(withJSONObject: ["event": "fixture", "index": index])
            data.append(10)
            writer.append(data)
        }
        writer.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let lines = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
        let indices = try lines.map { line -> Int in
            let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(entry["index"] as? Int)
        }
        XCTAssertEqual(Set(indices), Set(0..<100))
    }
    func testRotationBoundsStorageAndSnapshotPreservesEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = DiagnosticLogWriter(directory: root.appendingPathComponent("logs"), maxBytes: 100, retainedFiles: 3)
        for index in 0..<50 { writer.append(Data("{\"event\":\"fixture\",\"index\":\(index)}\n".utf8)) }
        writer.flush()
        let destination = root.appendingPathComponent("export")
        try writer.snapshot(to: destination)
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertGreaterThan(files.count, 0)
        for file in files {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 100)
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
            }
        }
    }
}
