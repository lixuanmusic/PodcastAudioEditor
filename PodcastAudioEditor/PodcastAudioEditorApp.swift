//
//  PodcastAudioEditorApp.swift
//  PodcastAudioEditor
//
//  Created by 李轩 on 2025/10/30.
//

import SwiftUI

@main
struct PodcastAudioEditorApp: App {
    var body: some Scene {
        WindowGroup {
            MainEditorView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Audio…") {
                    AudioFileManager.shared.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .appInfo) { }
        }
    }
}
