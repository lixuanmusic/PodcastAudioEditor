import SwiftUI

struct WaveformView: View {
    @ObservedObject var viewModel: AudioPlayerViewModel
    @Binding var isHovered: Bool
    
    @State private var isDragging: Bool = false
    @State private var waveformDataVersion: Int = 0
    
    // 统一计算波形宽度的辅助函数（与 ViewModel 保持一致）
    private func calculateActualWaveformWidth(_ geometry: GeometryProxy) -> CGFloat {
        guard viewModel.duration > 0 else { return geometry.size.width }
        
        let minPxPerSec: CGFloat = 50.0
        let minWidth = CGFloat(viewModel.duration) * minPxPerSec
        let baseWidth = max(geometry.size.width, minWidth)
        let result = baseWidth * viewModel.waveformScale
        
        print("🎨 WaveformView宽度: duration=\(viewModel.duration)s, geometryWidth=\(geometry.size.width), minWidth=\(minWidth), baseWidth=\(baseWidth), scale=\(viewModel.waveformScale), result=\(result)")
        
        return result
    }
    
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
                        
                        // Canvas 的 canvasSize.width 就是实际波形宽度（由外层 frame 设置）
                        let actualWaveformWidth = canvasSize.width
                        
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
                .frame(width: calculateActualWaveformWidth(geometry), alignment: .leading)
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
        
        let actualWaveformWidth = calculateActualWaveformWidth(geometry)
        let progress = CGFloat(viewModel.currentTime / viewModel.duration)
        let playedWidth = actualWaveformWidth * progress
        
        return playedWidth - viewModel.waveformScrollOffset
    }
    
    private func playbackIndicator(geometry: GeometryProxy) -> some View {
        let actualWaveformWidth = calculateActualWaveformWidth(geometry)
        let progress = viewModel.duration > 0 ? CGFloat(viewModel.currentTime / viewModel.duration) : 0
        let indicatorX = actualWaveformWidth * progress - viewModel.waveformScrollOffset
        
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .offset(x: indicatorX - 1)
    }
    
    private func seekAudio(at xPosition: CGFloat, in geometry: GeometryProxy) {
        guard viewModel.duration > 0 else { return }
        
        let actualWaveformWidth = calculateActualWaveformWidth(geometry)
        let normalizedPosition = xPosition / actualWaveformWidth
        let seekTime = Double(normalizedPosition) * viewModel.duration
        viewModel.audioEngine.seek(to: seekTime)
    }
}


