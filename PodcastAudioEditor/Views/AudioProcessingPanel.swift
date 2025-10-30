import SwiftUI

// 增益指示器视图
struct GainIndicatorView: View {
    let currentGain: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景条
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 6)
                
                // 中心线（0 dB）
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 1, height: 10)
                    .offset(x: geometry.size.width / 2)
                
                // 当前增益指示器
                let normalizedGain = (currentGain + 12) / 24  // -12~+12 映射到 0~1
                let clampedGain = CGFloat(max(0, min(1, normalizedGain)))
                
                Circle()
                    .fill(gainColor(currentGain))
                    .frame(width: 12, height: 12)
                    .offset(x: clampedGain * geometry.size.width - 6)
            }
        }
        .frame(height: 12)
    }
    
    private func gainColor(_ gain: Float) -> Color {
        let absGain = abs(gain)
        if absGain < 3 {
            return .green
        } else if absGain < 6 {
            return .orange
        } else {
            return .red
        }
    }
}

struct AudioProcessingPanel: View {
    @ObservedObject var processor: AudioProcessor
    @ObservedObject var analysisVM: AudioAnalysisViewModel
    @ObservedObject var audioEngine: AudioEngine
    @Binding var currentFileURL: URL?
    
    @State private var showExportDialog = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var showSuccessMessage = false
    
    // 监听分析完成
    private func checkAnalysisCompleted() {
        if !analysisVM.isAnalyzing && !analysisVM.features.isEmpty && processor.config.volumeBalanceEnabled {
            let gains = processor.calculateVolumeGains(features: analysisVM.features)
            
            // 如果功能已开启，设置增益并启用效果器
            if !gains.isEmpty {
                audioEngine.setVolumeBalanceGains(gains, hopSize: 768)
                audioEngine.setVolumeBalanceEnabled(true)
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            Text("音频优化")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            
            Divider()
            
            // 音量动态平衡模块
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("音量动态平衡", isOn: $processor.config.volumeBalanceEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: processor.config.volumeBalanceEnabled) { enabled in
                            if enabled {
                                if !analysisVM.features.isEmpty {
                                    // 计算增益
                                    let gains = processor.calculateVolumeGains(features: analysisVM.features)
                                    
                                    // 设置增益并启用效果器
                                    if !gains.isEmpty {
                                        audioEngine.setVolumeBalanceGains(gains, hopSize: 768)
                                        audioEngine.setVolumeBalanceEnabled(true)
                                    }
                                } else {
                                    // 如果没有特征，关闭开关
                                    processor.config.volumeBalanceEnabled = false
                                }
                            } else {
                                // 禁用效果器（不切换播放器）
                                audioEngine.setVolumeBalanceEnabled(false)
                            }
                        }
                    
                    Spacer()
                    
                    // 说明按钮
                    Button {
                        // 显示说明
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("自动调节音量，使响度保持在 -16 LUFS 附近")
                }
                
                if processor.config.volumeBalanceEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        // 当前增益显示（实时）
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("当前增益:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(String(format: "%+.1f", audioEngine.currentGainDB)) dB")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(gainColor(audioEngine.currentGainDB))
                            }
                            
                            // 增益指示器（-12 到 +12 dB）
                            GainIndicatorView(currentGain: audioEngine.currentGainDB)
                            
                            // 刻度标签
                            HStack {
                                Text("-12dB")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("0dB")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("+12dB")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        // 平均增益
                        HStack {
                            Text("平均增益:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(String(format: "%+.1f", processor.averageGainDB)) dB")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(gainColor(processor.averageGainDB))
                        }
                        
                        // 配置参数（折叠）
                        DisclosureGroup("配置参数") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("目标响度:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(String(format: "%.1f", processor.config.targetLUFS)) LUFS")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                
                                HStack {
                                    Text("调节范围:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(String(format: "%.0f", processor.config.minGainDB))dB ~ \(String(format: "%.0f", processor.config.maxGainDB))dB")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                
                                HStack {
                                    Text("平滑窗口:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(processor.config.smoothingWindow) 帧")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 12)
                }
            }
            .padding(.horizontal, 12)
            
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
        .onReceive(analysisVM.$isAnalyzing) { isAnalyzing in
            if !isAnalyzing {
                checkAnalysisCompleted()
            }
        }
    }
    
    // 增益颜色映射
    private func gainColor(_ gain: Float) -> Color {
        let absGain = abs(gain)
        if absGain < 3 {
            return .green
        } else if absGain < 6 {
            return .orange
        } else {
            return .red
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

