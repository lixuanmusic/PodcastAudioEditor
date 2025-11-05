import SwiftUI

/// 增益包络曲线视图 - 与波形完全绑定
struct GainEnvelopeCurveView: View {
    let envelopeData: GainEnvelopeData?
    let currentTime: Double
    let duration: Double
    let scrollOffset: CGFloat
    let scale: CGFloat
    let waveformWidth: CGFloat

    // 增益曲线参数
    private let minGainDB: Float = -12.0
    private let maxGainDB: Float = 12.0
    private let centerLineDB: Float = 0.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景
                Color(NSColor.controlBackgroundColor)

                // 网格线和增益曲线
                Canvas { context, size in
                    drawGridLines(context: &context, size: size)

                    if let data = envelopeData, !data.gains.isEmpty {
                        drawGainCurve(context: &context, data: data, size: size)
                    }

                    drawPlaybackLine(context: &context, size: size)
                }
            }
        }
    }

    // MARK: - 绘制网格线
    private func drawGridLines(context: inout GraphicsContext, size: CGSize) {
        // 水平网格线（dB 标记）
        let gains = [-12.0, -6.0, 0.0, 6.0, 12.0] as [Float]
        for gain in gains {
            let y = gainToYPosition(Float(gain), height: size.height)

            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))

            let color: Color = gain == 0 ? .gray.opacity(0.5) : .gray.opacity(0.2)
            var stroke = StrokeStyle(lineWidth: gain == 0 ? 1 : 0.5)
            if gain != 0 { stroke.dash = [4, 4] }

            context.stroke(path, with: .color(color), style: stroke)
        }
    }

    // MARK: - 绘制增益曲线
    private func drawGainCurve(context: inout GraphicsContext, data: GainEnvelopeData, size: CGSize) {
        guard !data.gains.isEmpty else { return }

        // 计算可见的时间范围
        let visibleDuration = duration / Double(scale)
        let visibleStart = Double(scrollOffset) / Double(waveformWidth) * visibleDuration
        let visibleEnd = visibleStart + visibleDuration

        // 采样增益曲线（避免过多点导致绘制缓慢）
        let frameTime = data.durationSeconds / Double(data.frameCount)
        // 修复：计算每帧在可见范围内占据的像素
        let pixelPerFrame = Double(size.width) * frameTime / visibleDuration
        let samplingInterval = max(1, Int(1.0 / max(pixelPerFrame, 0.1)))

        var curvePath = Path()
        var isFirst = true

        for (i, gain) in data.gains.enumerated() {
            if i % samplingInterval != 0 { continue }

            let timestamp = Double(i) * frameTime
            if timestamp < visibleStart || timestamp > visibleEnd { continue }

            // 计算在视图中的位置
            let relativeTime = timestamp - visibleStart
            let xPosition = (relativeTime / visibleDuration) * Double(size.width)
            let yPosition = gainToYPosition(gain, height: size.height)

            if isFirst {
                curvePath.move(to: CGPoint(x: xPosition, y: yPosition))
                isFirst = false
            } else {
                curvePath.addLine(to: CGPoint(x: xPosition, y: yPosition))
            }
        }

        // 绘制曲线
        context.stroke(
            curvePath,
            with: .color(.green.opacity(0.8)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )

        // 绘制曲线下方的填充（浅色）
        if !curvePath.isEmpty {
            var fillPath = curvePath
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()

            context.fill(fillPath, with: .color(.green.opacity(0.1)))
        }
    }

    // MARK: - 绘制播放进度线
    private func drawPlaybackLine(context: inout GraphicsContext, size: CGSize) {
        guard duration > 0 else { return }

        // 计算当前时刻相对于可见范围的位置
        let visibleDuration = duration / Double(scale)
        let visibleStart = Double(scrollOffset) / Double(waveformWidth) * visibleDuration
        let visibleEnd = visibleStart + visibleDuration

        if currentTime >= visibleStart && currentTime <= visibleEnd {
            let relativeTime = currentTime - visibleStart
            let xPosition = (relativeTime / visibleDuration) * Double(size.width)

            var path = Path()
            path.move(to: CGPoint(x: xPosition, y: 0))
            path.addLine(to: CGPoint(x: xPosition, y: size.height))

            context.stroke(
                path,
                with: .color(.white.opacity(0.6)),
                style: StrokeStyle(lineWidth: 1.5)
            )
        }
    }

    // MARK: - 辅助方法
    /// 将增益值转换为y坐标
    private func gainToYPosition(_ gain: Float, height: CGFloat) -> CGFloat {
        let normalizedGain = Double(gain - centerLineDB) / Double(maxGainDB - minGainDB)
        let yOffset = (0.5 - normalizedGain) * height
        return yOffset
    }
}

// MARK: - 预览
#Preview {
    ZStack {
        VStack(spacing: 0) {
            Text("增益包络曲线")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

            GainEnvelopeCurveView(
                envelopeData: GainEnvelopeData(
                    timestamps: Array(0..<200).map { Double($0) * 0.02 },
                    gains: Array(0..<200).map { Float(sin(Double($0) * 0.05) * 6.0) },
                    energyValues: Array(0..<200).map { Float($0) },
                    totalDuration: 4.0  // 预览数据的总时长
                ),
                currentTime: 2.0,
                duration: 4.0,
                scrollOffset: 0,
                scale: 1.0,
                waveformWidth: 300
            )
        }
        .frame(height: 60)
    }
}
