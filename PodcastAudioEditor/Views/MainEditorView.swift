import SwiftUI
import AppKit

struct MainEditorView: View {
    @StateObject var viewModel = AudioPlayerViewModel()
    @State private var isWaveformHovered: Bool = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        AudioFileManager.shared.presentOpenPanel()
                    } label: {
                        Label("导入", systemImage: "tray.and.arrow.down")
                    }

                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .keyboardShortcut(.space, modifiers: [])

                    Button {
                        viewModel.seekToBeginning()
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }

                    HStack {
                        Image(systemName: "speaker.wave.2.fill")
                        Slider(value: Binding(get: {
                            Double(viewModel.audioEngine.volume)
                        }, set: { viewModel.audioEngine.setVolume(Float($0)) }), in: 0...1)
                        .frame(width: 160)
                    }

                    Spacer()

                    Text(timeString(viewModel.currentTime))
                    Text("/")
                    Text(timeString(viewModel.duration)).foregroundStyle(.secondary)
                    
                    // 缩放级别显示
                    if viewModel.waveformScale > 1.0 {
                        Text("缩放: \(Int(viewModel.waveformScale * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)

                Divider()

                TimelineRuler(currentTime: viewModel.currentTime, duration: viewModel.duration, scale: viewModel.waveformScale, scrollOffset: viewModel.waveformScrollOffset, waveformWidth: viewModel.waveformWidth)
                    .frame(height: 28)

            ZStack(alignment: .topTrailing) {
                WaveformView(viewModel: viewModel, isHovered: $isWaveformHovered)
                    .frame(maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                
                // 音量自动化线叠加在波形上
                GeometryReader { geo in
                    AutomationView(viewModel: viewModel, geometry: geo)
                        .frame(maxHeight: .infinity)
                }
                
                // Toast 提示 - 使用 overlay 不占用空间
                if viewModel.showToast {
                    ToastView(message: viewModel.toastMessage)
                        .padding(.top, 12)
                        .padding(.trailing, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            }
            
            // 滚动条 - 完全贴到窗口下边缘
            if viewModel.isWaveformScrollable {
                HorizontalScrollbar(viewModel: viewModel)
                    .frame(height: 12)
                    .offset(y: 6) // 下移6px完全贴到窗口底部
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .onReceive(viewModel.$currentTime) { _ in
            if viewModel.isPlaying && viewModel.waveformScale > 1.0 {
                viewModel.updatePlaybackFollow()
            }
        }
        .onReceive(viewModel.$isPlaying) { isPlaying in
            if !isPlaying {
                viewModel.resetPlaybackFollow()
            }
        }
        .background(EventHandlingView(viewModel: viewModel, isWaveformHovered: isWaveformHovered))
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite else { return "00:00" }
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

// 横向滚动条（参考 Miniwave）
struct HorizontalScrollbar: View {
    @ObservedObject var viewModel: AudioPlayerViewModel
    
    @State private var isDragging = false
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 4)
                    .cornerRadius(2)
                
                Rectangle()
                    .fill(isDragging ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: thumbWidth(geometry: geometry), height: 6)
                    .cornerRadius(3)
                    .offset(x: thumbOffset(geometry: geometry))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    viewModel.isScrollbarDragging = true
                                    dragStartX = value.startLocation.x
                                    dragStartOffset = thumbOffset(geometry: geometry)
                                }
                                updateScrollOffset(dragLocation: value.location.x, geometry: geometry)
                            }
                            .onEnded { _ in
                                isDragging = false
                                viewModel.isScrollbarDragging = false
                            }
                    )
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
    
    private func thumbWidth(geometry: GeometryProxy) -> CGFloat {
        let availableWidth = geometry.size.width
        let scale = viewModel.waveformScale
        let thumbWidth = availableWidth / scale
        return max(20, thumbWidth)
    }
    
    private func thumbOffset(geometry: GeometryProxy) -> CGFloat {
        let availableWidth = geometry.size.width
        let thumbWidth = thumbWidth(geometry: geometry)
        let maxOffset = availableWidth - thumbWidth
        
        guard maxOffset > 0 else { return 0 }
        
        let visibleWidth = viewModel.waveformWidth
        let totalScaledWidth = visibleWidth * viewModel.waveformScale
        let maxScrollOffset = max(0, totalScaledWidth - visibleWidth)
        
        guard maxScrollOffset > 0 else { return 0 }
        
        let scrollRatio = viewModel.waveformScrollOffset / maxScrollOffset
        return scrollRatio * maxOffset
    }
    
    private func updateScrollOffset(dragLocation: CGFloat, geometry: GeometryProxy) {
        let availableWidth = geometry.size.width
        let thumbWidth = thumbWidth(geometry: geometry)
        let maxOffset = availableWidth - thumbWidth
        
        guard maxOffset > 0 else { return }
        
        let visibleWidth = viewModel.waveformWidth
        let totalScaledWidth = visibleWidth * viewModel.waveformScale
        let maxScrollOffset = max(0, totalScaledWidth - visibleWidth)
        
        guard maxScrollOffset > 0 else { return }
        
        let dragDistance = dragLocation - dragStartX
        let newOffset = max(0, min(maxOffset, dragStartOffset + dragDistance))
        let offsetRatio = newOffset / maxOffset
        let newScrollOffset = offsetRatio * maxScrollOffset
        
        viewModel.setWaveformScrollOffset(newScrollOffset)
    }
}

// Toast 提示视图
struct ToastView: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.7))
            )
    }
}

// 事件处理视图（参考 Miniwave EventManager）
struct EventHandlingView: NSViewRepresentable {
    let viewModel: AudioPlayerViewModel
    let isWaveformHovered: Bool
    
    func makeNSView(context: Context) -> NSView {
        let view = EventCapturingView()
        view.viewModel = viewModel
        view.isWaveformHovered = isWaveformHovered
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let eventView = nsView as? EventCapturingView {
            eventView.isWaveformHovered = isWaveformHovered
        }
    }
}

class EventCapturingView: NSView {
    var viewModel: AudioPlayerViewModel?
    var isWaveformHovered: Bool = false
    private var localScrollMonitor: Any?
    private var localMagnifyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        stopMonitoring()
        // 滚轮事件
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self = self,
                  let vm = self.viewModel,
                  self.isWaveformHovered,
                  vm.hasAudioFile else { return event }

            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let isPrecise = event.hasPreciseScrollingDeltas

            let mouseInView = self.convert(event.locationInWindow, from: nil)
            let mouseX = mouseInView.x
            let waveformWidth = vm.waveformWidth

            if isPrecise {
                if abs(deltaX) > abs(deltaY) * 1.05 {
                    vm.scrollWaveform(delta: -deltaX)
                    return nil
                } else if abs(deltaY) > abs(deltaX) * 1.05 {
                    struct Accumulator { static var y: CGFloat = 0 }
                    Accumulator.y += deltaY
                    if abs(Accumulator.y) >= 4 {
                        let zoomDelta: CGFloat = Accumulator.y < 0 ? 1 : -1
                        vm.zoomWaveformAtPoint(delta: zoomDelta, mouseX: mouseX, waveformWidth: waveformWidth)
                        Accumulator.y = 0
                    }
                    return nil
                }
                return nil
            } else {
                let zoomDelta: CGFloat = deltaY > 0 ? -1.0 : 1.0
                vm.zoomWaveformAtPoint(delta: zoomDelta, mouseX: mouseX, waveformWidth: waveformWidth)
                return nil
            }
        }

        // 捏合事件
        localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
            guard let self = self,
                  let vm = self.viewModel,
                  vm.hasAudioFile else { return event }

            struct PinchAccumulator { static var value: CGFloat = 0 }
            PinchAccumulator.value += event.magnification
            if abs(PinchAccumulator.value) >= 0.04 {
                let delta: CGFloat = PinchAccumulator.value > 0 ? 1 : -1
                let mouseInView = self.convert(event.locationInWindow, from: nil)
                let mouseX = mouseInView.x
                vm.zoomWaveformAtPoint(delta: delta, mouseX: mouseX, waveformWidth: vm.waveformWidth)
                PinchAccumulator.value = 0
            }
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor = localScrollMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMagnifyMonitor { NSEvent.removeMonitor(monitor) }
        localScrollMonitor = nil
        localMagnifyMonitor = nil
    }
}


