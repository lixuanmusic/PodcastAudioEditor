import AppKit
import Foundation

extension Notification.Name {
    static let didImportAudioFile = Notification.Name("didImportAudioFile")
}

final class AudioFileManager {
    static let shared = AudioFileManager()

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Import"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                NotificationCenter.default.post(name: .didImportAudioFile, object: nil, userInfo: ["url": url])
            }
        }
    }
}

