import SwiftUI

struct TimelineRuler: View {
    let currentTime: Double
    let duration: Double
    let scale: CGFloat
    let scrollOffset: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let totalScaledWidth = width * scale
            let marks = tickMarks(for: duration, pixelWidth: totalScaledWidth)

            ZStack(alignment: .topLeading) {
                ForEach(marks.indices, id: \.self) { i in
                    let mark = marks[i]
                    let x = CGFloat(mark.position) * totalScaledWidth - scrollOffset
                    
                    // 只绘制可见范围内的刻度
                    if x >= -10 && x <= width + 10 {
                        Path { p in
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: mark.major ? 20 : 10))
                        }
                        .stroke(Color.secondary.opacity(0.5), lineWidth: mark.major ? 1.0 : 0.5)

                        if mark.major {
                            Text(mark.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .position(x: x + 12, y: 24)
                        }
                    }
                }
            }
            .clipped()
        }
        .frame(height: 28)
    }

    private func tickMarks(for duration: Double, pixelWidth: CGFloat) -> [(position: CGFloat, label: String, major: Bool)] {
        guard duration > 0 else { return [] }
        let approxStepPx: CGFloat = 80
        let stepTime = max(1.0, Double(approxStepPx / pixelWidth) * duration)
        let nice = niceStep(stepTime)
        var result: [(CGFloat, String, Bool)] = []
        var t = 0.0
        while t <= duration + 0.0001 {
            let pos = CGFloat(t / duration)
            let major = fmod(t, nice * 5) < 0.001 || t == 0
            let label = timeString(t)
            result.append((pos, label, major))
            t += nice
        }
        return result
    }

    private func niceStep(_ s: Double) -> Double {
        if s < 2 { return 1 }
        if s < 5 { return 2 }
        if s < 10 { return 5 }
        if s < 30 { return 10 }
        if s < 60 { return 15 }
        if s < 120 { return 30 }
        if s < 300 { return 60 }
        if s < 600 { return 120 }
        return 300
    }

    private func timeString(_ t: Double) -> String {
        let total = Int(t.rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}


