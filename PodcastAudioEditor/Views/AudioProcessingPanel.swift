import SwiftUI

struct AudioProcessingPanel: View {
    @ObservedObject var processor: AudioProcessor
    @ObservedObject var analysisVM: AudioAnalysisViewModel
    @ObservedObject var audioEngine: AudioEngine
    @Binding var currentFileURL: URL?

    @State private var showExportDialog = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var showSuccessMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            Text("音频优化")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Divider()

            // 暂未实现的功能区域（保留位置）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("更多优化功能")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)

            Divider()

            // 导出按钮
            HStack {
                Spacer()

                if isExporting {
                    ProgressView(value: exportProgress) {
                        Text("处理中...")
                            .font(.caption)
                    }
                    .frame(width: 200)
                } else {
                    Button {
                        exportProcessedAudio()
                    } label: {
                        Label("导出处理后的音频", systemImage: "square.and.arrow.up")
                    }
                    .disabled(currentFileURL == nil || analysisVM.features.isEmpty)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if showSuccessMessage {
                HStack {
                    Spacer()
                    Text("✓ 导出成功！")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(.bottom, 4)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .padding(8)
    }

    private func exportProcessedAudio() {
        guard let inputURL = currentFileURL else { return }
        guard !analysisVM.features.isEmpty else { return }

        // 打开保存对话框
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.audio]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.title = "导出处理后的音频"
        savePanel.message = "选择导出位置"
        savePanel.nameFieldStringValue = "processed_\(inputURL.deletingPathExtension().lastPathComponent).m4a"

        savePanel.begin { response in
            if response == .OK, let outputURL = savePanel.url {
                Task {
                    await processAndExport(inputURL: inputURL, outputURL: outputURL)
                }
            }
        }
    }

    private func processAndExport(inputURL: URL, outputURL: URL) async {
        isExporting = true
        exportProgress = 0.0
        showSuccessMessage = false

        do {
            // 计算增益
            let gains = processor.calculateVolumeGains(features: analysisVM.features)

            // 处理音频
            try await processor.processAudioFile(
                inputURL: inputURL,
                outputURL: outputURL,
                gains: gains,
                hopSize: 768,
                frameSize: 1024
            ) { progress in
                DispatchQueue.main.async {
                    exportProgress = progress
                }
            }

            DispatchQueue.main.async {
                isExporting = false
                showSuccessMessage = true

                // 3秒后隐藏成功消息
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    showSuccessMessage = false
                }
            }

        } catch {
            print("❌ 处理失败: \(error.localizedDescription)")
            DispatchQueue.main.async {
                isExporting = false
            }
        }
    }
}

