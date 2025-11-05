import SwiftUI
import AppKit

struct MainEditorView: View {
    @StateObject var viewModel = AudioPlayerViewModel()
    @StateObject var analysisVM = AudioAnalysisViewModel()
    @StateObject var audioProcessor = AudioProcessor()
    @State private var isWaveformHovered: Bool = false
    @State private var showAnalysisWindow = false
    @State private var currentFileURL: URL?

    // 分析完成提示
    @State private var showAnalysisCompleted = false
    @State private var analysisCompletedTimer: Timer?
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // 控制栏 - 扁平大按钮风格
                HStack(spacing: 12) {
                    // 分析按钮
                    Button(action: {
                        if analysisVM.isCurrentFileAnalyzed {
                            // 已分析 - 打开分析结果窗口
                            AnalysisWindowManager.shared.show(analysisVM: analysisVM)
                        } else if let url = currentFileURL {
                            // 未分析 - 开始分析
                            analysisVM.analyzeAudioFile(url: url)
                        }
                    }) {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(currentFileURL == nil || analysisVM.isAnalyzing)
                    .help(analysisVM.isCurrentFileAnalyzed ? "查看分析结果" : "分析音频")

                    // 播放/暂停按钮
                    Button(action: {
                        viewModel.togglePlayPause()
                    }) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help(viewModel.isPlaying ? "暂停" : "播放")

                    // 重新开始按钮
                    Button(action: {
                        viewModel.seekToBeginning()
                    }) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .help("重新开始")

                    Spacer()

                    // 时间显示
                    HStack(spacing: 2) {
                        Text(timeString(viewModel.currentTime))
                            .font(.system(size: 12, design: .monospaced))
                        Text("/")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12, design: .monospaced))
                        Text(timeString(viewModel.duration))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)

                        // 缩放级别显示
                        if viewModel.waveformScale > 1.0 {
                            Text("  ")
                            Text("缩放: \(Int(viewModel.waveformScale * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // 导出按钮
                    ExportButton(
                        processor: audioProcessor,
                        analysisVM: analysisVM,
                        currentFileURL: $currentFileURL
                    )
                    .help("导出处理后的音频")
                }
                .padding(8)

                Divider()

                TimelineRuler(currentTime: viewModel.currentTime, duration: viewModel.duration, scale: viewModel.waveformScale, scrollOffset: viewModel.waveformScrollOffset, waveformWidth: viewModel.waveformWidth)
                    .frame(height: 28)

                ZStack(alignment: .topTrailing) {
                    WaveformView(viewModel: viewModel, isHovered: $isWaveformHovered)
                        .background(Color(NSColor.controlBackgroundColor))

                    // Toast 提示 - 使用 overlay 不占用空间
                    if analysisVM.isAnalyzing {
                        // 分析进度中 Toast
                        VStack(spacing: 8) {
                            ProgressView(value: analysisVM.analysisProgress)
                                .frame(width: 150)
                            HStack(spacing: 6) {
                                Text("分析中...")
                                    .font(.caption)
                                Text("\(Int(analysisVM.analysisProgress * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.top, 12)
                        .padding(.trailing, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else if showAnalysisCompleted {
                        // 分析完成提示 Toast
                        Text("✓ 分析完成")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.green.opacity(0.8))
                            )
                            .padding(.top, 12)
                            .padding(.trailing, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if viewModel.showToast {
                        ToastView(message: viewModel.toastMessage)
                            .padding(.top, 12)
                            .padding(.trailing, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                
                Divider()

                // AU 效果器链面板
                EffectSlotsPanel(audioEngine: viewModel.audioEngine)
                    .frame(height: 150)
            }

            // 滚动条 - 在效果器链面板上方
            if viewModel.isWaveformScrollable {
                HorizontalScrollbar(viewModel: viewModel)
                    .frame(height: 12)
                    .offset(y: -150) // 向上偏移效果器链面板的高度
            }
        }
        .ignoresSafeArea(.all, edges: .bottom)
        .onReceive(viewModel.$currentTime) { currentTime in
            if viewModel.isPlaying && viewModel.waveformScale > 1.0 {
                viewModel.updatePlaybackFollow()
            }
            
            // 增益更新由AudioEngine在updateCurrentTime中自动处理
        }
        .onReceive(viewModel.$isPlaying) { isPlaying in
            if !isPlaying {
                viewModel.resetPlaybackFollow()
            }
        }
        .background(EventHandlingView(viewModel: viewModel, isWaveformHovered: isWaveformHovered))
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("didImportAudioFile"))) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                currentFileURL = url
                // 更新analysisVM的当前文件URL
                analysisVM.currentFileURL = url
                // 切换文件时重置分析完成标记
                showAnalysisCompleted = false
            }
        }
        .onReceive(analysisVM.$isAnalyzing) { isAnalyzing in
            if !isAnalyzing && analysisVM.analysisProgress >= 1.0 {
                // 分析完成 - 显示完成提示2秒
                showAnalysisCompleted = true

                // 取消之前的计时器
                analysisCompletedTimer?.invalidate()

                // 设置2秒后隐藏
                analysisCompletedTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    withAnimation {
                        showAnalysisCompleted = false
                    }
                }
            }
        }
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


