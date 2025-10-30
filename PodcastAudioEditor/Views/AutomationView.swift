import SwiftUI

struct AutomationView: View {
    @ObservedObject var viewModel: AudioPlayerViewModel
    let geometry: GeometryProxy
    
    @State private var draggedPointId: UUID?
    
    var body: some View {
        GeometryReader { canvasGeo in
            Canvas { context, canvasSize in
                let duration = viewModel.duration
                guard duration > 0 else { return }
                
                let automation = viewModel.volumeAutomation
                guard !automation.points.isEmpty else { return }
                
                let height = canvasSize.height
                let minPxPerSec: CGFloat = 50.0
                let minWidth = CGFloat(duration) * minPxPerSec
                let baseWidth = max(viewModel.waveformWidth, minWidth)
                let totalScaledWidth = baseWidth * viewModel.waveformScale
                
                // 绘制自动化线
                var path = Path()
                var isFirst = true
                
                for point in automation.points {
                    let x = totalScaledWidth * CGFloat(point.time / duration)
                    let normalizedDb = CGFloat((point.dbValue + 12.0) / 24.0)
                    let y = height * (1.0 - normalizedDb)
                    
                    if isFirst {
                        path.move(to: CGPoint(x: x, y: y))
                        isFirst = false
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                
                // 绘制线条
                context.stroke(
                    path,
                    with: .color(Color.accentColor),
                    lineWidth: 2.0
                )
                
                // 绘制控制点
                for point in automation.points {
                    let x = totalScaledWidth * CGFloat(point.time / duration)
                    let normalizedDb = CGFloat((point.dbValue + 12.0) / 24.0)
                    let y = height * (1.0 - normalizedDb)
                    
                    let isSelected = point.id == automation.selectedPointId
                    let pointSize: CGFloat = isSelected ? 10 : 6
                    
                    var pointPath = Path()
                    pointPath.addEllipse(in: CGRect(
                        x: x - pointSize / 2,
                        y: y - pointSize / 2,
                        width: pointSize,
                        height: pointSize
                    ))
                    
                    context.fill(
                        pointPath,
                        with: .color(isSelected ? Color.white : Color.accentColor)
                    )
                    
                    if isSelected {
                        context.stroke(
                            pointPath,
                            with: .color(Color.accentColor),
                            lineWidth: 2.0
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDragChanged(value, canvasGeo: canvasGeo)
                    }
                    .onEnded { _ in
                        handleDragEnded()
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    handleHover(at: location, canvasGeo: canvasGeo)
                case .ended:
                    break
                }
            }
        }
        .frame(height: geometry.size.height)
    }
    
    private func handleHover(at location: CGPoint, canvasGeo: GeometryProxy) {
        let height = geometry.size.height
        let duration = viewModel.duration
        guard duration > 0 else { return }
        
        let minPxPerSec: CGFloat = 50.0
        let minWidth = CGFloat(duration) * minPxPerSec
        let baseWidth = max(viewModel.waveformWidth, minWidth)
        let totalScaledWidth = baseWidth * viewModel.waveformScale
        
        let scrolledX = location.x + viewModel.waveformScrollOffset
        
        // 检查是否在控制点附近
        let tolerance: CGFloat = 10.0
        var isNearPoint = false
        
        for point in viewModel.volumeAutomation.points {
            let pointX = totalScaledWidth * CGFloat(point.time / duration)
            let normalizedDb = CGFloat((point.dbValue + 12.0) / 24.0)
            let pointY = height * (1.0 - normalizedDb)
            
            if abs(scrolledX - pointX) < tolerance && abs(location.y - pointY) < tolerance {
                isNearPoint = true
                if viewModel.volumeAutomation.selectedPointId == nil {
                    viewModel.volumeAutomation.selectedPointId = point.id
                }
                break
            }
        }
        
        if !isNearPoint && draggedPointId == nil {
            if viewModel.volumeAutomation.selectedPointId != nil {
                viewModel.volumeAutomation.selectedPointId = nil
            }
        }
    }
    
    private func handleDragChanged(_ value: DragGesture.Value, canvasGeo: GeometryProxy) {
        let height = geometry.size.height
        let duration = viewModel.duration
        guard duration > 0 else { return }
        
        let minPxPerSec: CGFloat = 50.0
        let minWidth = CGFloat(duration) * minPxPerSec
        let baseWidth = max(viewModel.waveformWidth, minWidth)
        let totalScaledWidth = baseWidth * viewModel.waveformScale
        
        // 首次拖动时检查是否点击了控制点
        if draggedPointId == nil {
            let tolerance: CGFloat = 10.0
            for point in viewModel.volumeAutomation.points {
                let pointX = totalScaledWidth * CGFloat(point.time / duration)
                let normalizedDb = CGFloat((point.dbValue + 12.0) / 24.0)
                let pointY = height * (1.0 - normalizedDb)
                
                if abs(value.startLocation.x + viewModel.waveformScrollOffset - pointX) < tolerance &&
                   abs(value.startLocation.y - pointY) < tolerance {
                    draggedPointId = point.id
                    viewModel.volumeAutomation.selectedPointId = point.id
                    break
                }
            }
            
            // 如果没有点击到控制点，则添加新点
            if draggedPointId == nil {
                let scrolledX = value.startLocation.x + viewModel.waveformScrollOffset
                let normalizedX = scrolledX / totalScaledWidth
                let time = Double(normalizedX) * duration
                
                let normalizedY = 1.0 - (value.startLocation.y / height)
                let dbValue = Double(normalizedY) * 24.0 - 12.0
                
                viewModel.volumeAutomation.addPoint(time: time, dbValue: dbValue)
                draggedPointId = viewModel.volumeAutomation.selectedPointId
            }
        }
        
        // 拖动控制点
        if let pointId = draggedPointId {
            let scrolledX = value.location.x + viewModel.waveformScrollOffset
            let newTime = Double(scrolledX / totalScaledWidth) * duration
            
            let normalizedY = 1.0 - (value.location.y / height)
            let dbValue = Double(normalizedY) * 24.0 - 12.0
            
            viewModel.volumeAutomation.updatePoint(pointId, time: max(0, newTime), dbValue: dbValue)
        }
    }
    
    private func handleDragEnded() {
        draggedPointId = nil
    }
}
