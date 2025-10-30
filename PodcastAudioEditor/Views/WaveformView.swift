import SwiftUI

struct WaveformView: View {
    @ObservedObject var viewModel: AudioPlayerViewModel
    @Binding var isHovered: Bool
    
    @State private var isDragging: Bool = false
    @State private var waveformDataVersion: Int = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.12))
                
                // 波形内容，支持水平偏移和缩放（竖条样式，参照 podcast_audio_tool）
                ZStack(alignment: .leading) {
                    // 背景
                    Rectangle().fill(Color.gray.opacity(0.08))
                    
                    // 竖条波形
                    Canvas { context, canvasSize in
                        let waveformData = viewModel.audioEngine.waveformData
                        guard !waveformData.isEmpty else { return }
                        
                        let height = canvasSize.height
                        let barWidth: CGFloat = 3.0      // 竖条宽度 3px
                        let barGap: CGFloat = 2.0        // 竖条间隔 2px
                        let barRadius: CGFloat = 3.0     // 竖条圆角 3px
                        let barPitch = barWidth + barGap // 竖条周期（宽度 + 间隔）
                        let scale = viewModel.waveformScale
                        
                        // 使用第一声道数据（如果是多声道则合并显示）
                        let displayWaveformData = waveformData.isEmpty ? [] : waveformData[0]
                        
                        for (index, amplitude) in displayWaveformData.enumerated() {
                            let x = CGFloat(index) * barPitch * scale
                            
                            // 计算竖条高度（归一化到 0-1）
                            let normalizedAmplitude = min(max(CGFloat(amplitude), 0), 1.0)
                            let barHeight = height * normalizedAmplitude
                            let barY = (height - barHeight) / 2  // 竖条从中心向上下延伸
                            
                            // 绘制竖条（带圆角）
                            let barRect = CGRect(
                                x: x,
                                y: barY,
                                width: barWidth * scale,
                                height: barHeight
                            )
                            
                            var path = Path()
                            path.addRoundedRect(
                                in: barRect,
                                cornerSize: CGSize(width: barRadius * scale, height: barRadius * scale)
                            )
                            
                            context.fill(path, with: .color(Color.primary.opacity(0.6)))
                        }
                    }
                    .clipped()
                    .id(waveformDataVersion)
                }
                .frame(width: geometry.size.width * viewModel.waveformScale, alignment: .leading)
                .offset(x: -viewModel.waveformScrollOffset)
                .clipped()
                
                // 已播放遮罩
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: maskWidth(for: geometry))
                
                // 播放头
                playbackIndicator(geometry: geometry)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging && (abs(value.translation.width) > 5 || abs(value.translation.height) > 5) {
                            isDragging = true
                        }
                    }
                    .onEnded { value in
                        if !isDragging {
                            seekAudio(at: value.location.x + viewModel.waveformScrollOffset, in: geometry)
                        }
                        isDragging = false
                    }
            )
            .onAppear {
                viewModel.updateWaveformWidth(geometry.size.width)
            }
            .onChange(of: geometry.size.width) { newWidth in
                viewModel.updateWaveformWidth(newWidth)
            }
            .onChange(of: viewModel.audioEngine.waveformData.count) { _ in
                waveformDataVersion += 1
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func maskWidth(for geometry: GeometryProxy) -> CGFloat {
        let progress = viewModel.duration > 0 ? CGFloat(viewModel.currentTime / viewModel.duration) : 0
        let scaledWidth = geometry.size.width * viewModel.waveformScale * progress
        return scaledWidth - viewModel.waveformScrollOffset
    }
    
    private func playbackIndicator(geometry: GeometryProxy) -> some View {
        let progress = viewModel.duration > 0 ? CGFloat(viewModel.currentTime / viewModel.duration) : 0
        let indicatorX = geometry.size.width * viewModel.waveformScale * progress - viewModel.waveformScrollOffset
        
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .offset(x: indicatorX - 1)
    }
    
    private func seekAudio(at xPosition: CGFloat, in geometry: GeometryProxy) {
        let totalScaledWidth = geometry.size.width * viewModel.waveformScale
        let normalizedPosition = xPosition / totalScaledWidth
        let seekTime = Double(normalizedPosition) * viewModel.duration
        viewModel.audioEngine.seek(to: seekTime)
    }
}


