import AppKit
import SwiftUI

/// The original artwork's full SVG timelines, baked at Retina resolution.
/// Playback is native Core Animation; no WebKit process or per-frame SwiftUI updates.
struct AnimatedSVGView: NSViewRepresentable {
    let name: String
    var animationEnabled = true
    var pauseAfterCycle = false
    var randomRestart = false
    var onReady: (@MainActor @Sendable () -> Void)?

    func makeNSView(context: Context) -> ShelfArtworkPlayer {
        let view = ShelfArtworkPlayer()
        updateNSView(view, context: context)
        // Avoid mutating SwiftUI state during updateNSView.
        if let onReady { Task { @MainActor in onReady() } }
        return view
    }

    func updateNSView(_ view: ShelfArtworkPlayer, context: Context) {
        view.configure(name: name, enabled: animationEnabled,
                       once: pauseAfterCycle, idle: randomRestart)
    }

    static func dismantleNSView(_ view: ShelfArtworkPlayer, coordinator: ()) {
        view.stop()
    }
}
