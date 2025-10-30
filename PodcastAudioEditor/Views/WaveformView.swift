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
                
                // 波形内容，支持水平偏移和缩放（竖条样式，完全参照 WaveSurfer.js）
                ZStack(alignment: .leading) {
                    // 背景
                    Rectangle().fill(Color.gray.opacity(0.08))
                    
                    // 竖条波形
                    Canvas { context, canvasSize in
                        let waveformData = viewModel.audioEngine.waveformData
                        guard !waveformData.isEmpty else { return }
                        
                        let duration = viewModel.duration
                        guard duration > 0 else { return }
                        
                        let height = canvasSize.height
                        let barWidth: CGFloat = 3.0      // 竖条宽度 3px（固定）
                        let barGap: CGFloat = 2.0        // 竖条间隔 2px（固定）
                        let barRadius: CGFloat = 3.0     // 竖条圆角 3px
                        let barPitch = barWidth + barGap // 竖条周期 5px（固定）
                        
                        // 使用第一声道数据
                        let displayWaveformData = waveformData.isEmpty ? [] : waveformData[0]
                        guard !displayWaveformData.isEmpty else { return }
                        
                        // WaveSurfer 逻辑：
                        // 1. 基础波形宽度 = 音频时长 × minPxPerSec（默认50）
                        // 2. 实际波形宽度 = 基础宽度 × 缩放因子
                        // 3. 竖条数量 = 实际波形宽度 / barPitch
                        
                        let minPxPerSec: CGFloat = 50.0  // 参照 WaveSurfer 默认值
                        let baseWaveformWidth = CGFloat(duration) * minPxPerSec
                        let scale = viewModel.waveformScale
                        let actualWaveformWidth = baseWaveformWidth * scale
                        
                        // 计算应该显示多少个竖条
                        let visibleBarsCount = Int(ceil(actualWaveformWidth / barPitch))
                        
                        // 从波形数据中采样
                        let dataPointCount = displayWaveformData.count
                        
                        for barIndex in 0..<visibleBarsCount {
                            let x = CGFloat(barIndex) * barPitch
                            
                            // 映射到波形数据索引
                            let dataIndex = Int(Float(barIndex) / Float(visibleBarsCount) * Float(dataPointCount))
                            let safeDataIndex = min(dataIndex, dataPointCount - 1)
                            let amplitude = displayWaveformData[safeDataIndex]
                            
                            // 计算竖条高度（归一化到 0-1）
                            let normalizedAmplitude = min(max(CGFloat(amplitude), 0), 1.0)
                            let barHeight = height * normalizedAmplitude
                            let barY = (height - barHeight) / 2  // 竖条从中心向上下延伸
                            
                            // 绘制竖条（带圆角）
                            let barRect = CGRect(
                                x: x,
                                y: barY,
                                width: barWidth,
                                height: barHeight
                            )
                            
                            var path = Path()
                            path.addRoundedRect(
                                in: barRect,
                                cornerSize: CGSize(width: barRadius, height: barRadius)
                            )
                            
                            context.fill(path, with: .color(Color.primary.opacity(0.6)))
                        }
                    }
                    .clipped()
                    .id(waveformDataVersion)
                }
                .frame(width: max(geometry.size.width, CGFloat(viewModel.duration) * 50.0 * viewModel.waveformScale), alignment: .leading)
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
        guard viewModel.duration > 0 else { return 0 }
        
        // WaveSurfer 逻辑：基于音频时长和像素密度计算实际宽度
        let minPxPerSec: CGFloat = 50.0
        let baseWaveformWidth = CGFloat(viewModel.duration) * minPxPerSec
        let actualWaveformWidth = baseWaveformWidth * viewModel.waveformScale
        
        let progress = CGFloat(viewModel.currentTime / viewModel.duration)
        let playedWidth = actualWaveformWidth * progress
        
        return playedWidth - viewModel.waveformScrollOffset
    }
    
    private func playbackIndicator(geometry: GeometryProxy) -> some View {
        let minPxPerSec: CGFloat = 50.0
        let baseWaveformWidth = CGFloat(viewModel.duration) * minPxPerSec
        let actualWaveformWidth = baseWaveformWidth * viewModel.waveformScale
        
        let progress = viewModel.duration > 0 ? CGFloat(viewModel.currentTime / viewModel.duration) : 0
        let indicatorX = actualWaveformWidth * progress - viewModel.waveformScrollOffset
        
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .offset(x: indicatorX - 1)
    }
    
    private func seekAudio(at xPosition: CGFloat, in geometry: GeometryProxy) {
        guard viewModel.duration > 0 else { return }
        
        // WaveSurfer 逻辑：基于实际波形宽度计算位置
        let minPxPerSec: CGFloat = 50.0
        let baseWaveformWidth = CGFloat(viewModel.duration) * minPxPerSec
        let actualWaveformWidth = baseWaveformWidth * viewModel.waveformScale
        
        let normalizedPosition = xPosition / actualWaveformWidth
        let seekTime = Double(normalizedPosition) * viewModel.duration
        viewModel.audioEngine.seek(to: seekTime)
    }
}


