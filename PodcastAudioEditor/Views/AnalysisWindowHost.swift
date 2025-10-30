import SwiftUI
import AppKit

final class AnalysisWindowManager {
    static let shared = AnalysisWindowManager()
    private var windowController: NSWindowController?

    func show(analysisVM: AudioAnalysisViewModel) {
        if let wc = windowController {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = AudioAnalysisWindow(analysisVM: analysisVM)
        let hosting = NSHostingView(rootView: contentView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "音频分析结果"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSView()
        window.contentView?.addSubview(hosting)

        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = true
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.windowController = wc
    }

    func close() {
        windowController?.close()
        windowController = nil
    }
}
