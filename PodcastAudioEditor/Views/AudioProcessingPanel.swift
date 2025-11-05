import SwiftUI

// 导出按钮组件 - 用于在控制栏中使用
struct ExportButton: View {
    @ObservedObject var processor: AudioProcessor
    @ObservedObject var analysisVM: AudioAnalysisViewModel
    @Binding var currentFileURL: URL?

    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var showSuccessMessage = false

    var body: some View {
        VStack(spacing: 4) {
            if isExporting {
                // 导出中 - 显示进度条
                VStack(spacing: 4) {
                    ProgressView(value: exportProgress)
                        .frame(height: 4)
                    Text("导出中...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 100)
            } else if showSuccessMessage {
                // 成功提示
                Text("✓ 导出成功！")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                // 导出按钮
                Button(action: exportProcessedAudio) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(currentFileURL == nil || analysisVM.features.isEmpty)
                .help("导出处理后的音频")
            }
        }
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

