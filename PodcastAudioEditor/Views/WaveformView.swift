import SwiftUI

struct WaveformView: View {
    @ObservedObject var viewModel: AudioPlayerViewModel
    @Binding var isHovered: Bool
    
    @State private var isDragging: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.12))
                
                // 波形内容，支持水平偏移和缩放
                ZStack(alignment: .leading) {
                    ForEach(0..<viewModel.audioEngine.waveformData.count, id: \.self) { channel in
                        WaveformChannelView(
                            waveformData: viewModel.audioEngine.waveformData[channel],
                            channelIndex: channel,
                            totalChannels: viewModel.audioEngine.waveformData.count,
                            geometry: geometry,
                            scale: viewModel.waveformScale
                        )
                    }
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
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation((viewModel.isAnimatingSeek || viewModel.isZooming || viewModel.isScrolling) ? nil : .easeInOut(duration: 0.3), value: viewModel.waveformScrollOffset)
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

// 单声道波形渲染（参考 Miniwave）
struct WaveformChannelView: View {
    let waveformData: [Float]
    let channelIndex: Int
    let totalChannels: Int
    let geometry: GeometryProxy
    let scale: CGFloat

    var body: some View {
        waveformPath
            .fill(Color.primary.opacity(0.7))
    }

    private var waveformPath: Path {
        Path { path in
            guard !waveformData.isEmpty else { return }

            let channelHeight = geometry.size.height / CGFloat(totalChannels)
            let yOffset = channelHeight * CGFloat(channelIndex)
            let midY = yOffset + channelHeight / 2
            let totalScaledWidth = geometry.size.width * scale

            path.move(to: CGPoint(x: 0, y: midY))

            // 绘制上半部分
            for (index, sample) in waveformData.enumerated() {
                let x = CGFloat(index) / CGFloat(waveformData.count) * totalScaledWidth
                let y = midY - CGFloat(sample) * channelHeight / 2
                path.addLine(to: CGPoint(x: x, y: y))
            }

            // 绘制下半部分
            for (index, sample) in waveformData.enumerated().reversed() {
                let x = CGFloat(index) / CGFloat(waveformData.count) * totalScaledWidth
                let y = midY + CGFloat(sample) * channelHeight / 2
                path.addLine(to: CGPoint(x: x, y: y))
            }

            path.closeSubpath()
        }
    }
}


