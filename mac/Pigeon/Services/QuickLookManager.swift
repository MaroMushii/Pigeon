import AppKit
import QuickLookUI

/// Drives the system QLPreviewPanel for a single file URL at a time.
/// Because QLPreviewPanel is a singleton NSPanel, this is also a singleton.
///
/// `previewURL` is `nonisolated(unsafe)` because QLPreviewPanel always calls
/// its data source on the main thread — matching where `show(_:)` writes it.
final class QuickLookManager: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookManager()

    nonisolated(unsafe) private var previewURL: URL?

    @MainActor
    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
