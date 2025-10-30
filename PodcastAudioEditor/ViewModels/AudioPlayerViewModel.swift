import SwiftUI
import AVFoundation
import Combine

class AudioPlayerViewModel: ObservableObject {
    @Published var audioEngine = AudioEngine.shared // Use the shared instance
    @Published var volumeAutomation = VolumeAutomation()  // 新增音量自动化
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var waveformScale: CGFloat = 1.0
    @Published var waveformScrollOffset: CGFloat = 0.0
    @Published var hasAudioFile: Bool = false
    
    // Zoom/Scroll states for animation control
    @Published var isZooming: Bool = false
    @Published var isScrolling: Bool = false
    @Published var isAnimatingSeek: Bool = false
    @Published var isScrollbarDragging: Bool = false
    
    // Playback follow
    @Published var followPlayback: Bool = true
    @Published var waveformWidth: CGFloat = 800 // Actual width will be updated by GeometryReader
    private var isPlaybackCentered: Bool = false
    private var playbackFollowTimer: Timer?
    
    // Toast
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    private var toastTimer: Timer?
    
    // 动态最小缩放（适配全长）
    private var minPxPerSec: CGFloat { 50.0 }
    private var minZoomScale: CGFloat {
        guard duration > 0, waveformWidth > 0 else { return 1.0 }
        let minWidth = CGFloat(duration) * minPxPerSec
        let baseWidth = max(waveformWidth, minWidth)
        let fitScale = waveformWidth / baseWidth
        // 移除固定下限，允许缩小到完整长度所需比例
        return min(fitScale, 1.0)
    }
    private let maxZoomScale: CGFloat = 20.0
    private var didFitAfterLoad: Bool = false
    
    private var cancellables: Set<AnyCancellable> = []
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        audioEngine.$isPlaying
            .assign(to: &$isPlaying)
        
        audioEngine.$currentTime
            .assign(to: &$currentTime)
        
        audioEngine.$duration
            .sink { [weak self] d in
                guard let self = self else { return }
                self.duration = d
                self.maybeFitToFullLength()
            }
            .store(in: &cancellables)
        
        audioEngine.$waveformData
            .map { !$0.isEmpty }
            .sink { [weak self] has in
                guard let self = self else { return }
                self.hasAudioFile = has
                if has {
                    // 新文件已生成波形数据，重置适配标记并适配全长
                    self.didFitAfterLoad = false
                    self.volumeAutomation.clear()  // 清除旧自动化数据
                    self.maybeFitToFullLength()
                }
            }
            .store(in: &cancellables)
    }
    
    private func maybeFitToFullLength() {
        // 首次加载后，自动适配到全长
        guard hasAudioFile, duration > 0 else { return }
        if !didFitAfterLoad {
            waveformScale = minZoomScale
            setWaveformScrollOffset(0)
            didFitAfterLoad = true
        }
    }
    
    func togglePlayPause() {
        if isPlaying {
            audioEngine.pause()
        } else {
            audioEngine.play()
        }
    }
    
    func seekToBeginning() {
        audioEngine.seek(to: 0)
    }
    
    func showToast(message: String) {
        toastTimer?.invalidate()
        toastMessage = message
        showToast = true
        
        toastTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            DispatchQueue.main.async {
                self.showToast = false
            }
        }
    }
    
    // MARK: - Waveform Zoom & Scroll
    
    func updateWaveformWidth(_ width: CGFloat) {
        waveformWidth = width
        // 窗口变化时，确保不会小于动态最小缩放（保持可见）
        if waveformScale < minZoomScale {
            waveformScale = minZoomScale
            setWaveformScrollOffset(0)
        }
    }
    
    func setWaveformScrollOffset(_ offset: CGFloat) {
        let actualWaveformWidth = calculateActualWaveformWidth()
        let maxScrollOffset = max(0, actualWaveformWidth - waveformWidth)
        waveformScrollOffset = max(0, min(maxScrollOffset, offset))
    }
    
    func zoomWaveformAtPoint(delta: CGFloat, mouseX: CGFloat, waveformWidth: CGFloat) {
        let zoomFactor = delta > 0 ? 1.1 : 0.9
        let newScaleRaw = waveformScale * zoomFactor
        let newScale = max(minZoomScale, min(maxZoomScale, newScaleRaw))
        
        guard newScale != waveformScale else {
            if waveformScale >= maxZoomScale && delta > 0 {
                showToast(message: "已达到最大缩放")
            } else if waveformScale <= minZoomScale && delta < 0 {
                showToast(message: "已达到最小缩放")
            }
            return
        }
        
        isZooming = true
        
        let oldActualWidth = calculateActualWaveformWidth()
        let mousePositionInWaveformRatio = (mouseX + waveformScrollOffset) / oldActualWidth
        
        waveformScale = newScale
        
        let newActualWidth = calculateActualWaveformWidth()
        let newMousePositionInWaveform = mousePositionInWaveformRatio * newActualWidth
        let newScrollOffset = newMousePositionInWaveform - mouseX
        setWaveformScrollOffset(newScrollOffset)
        
        adjustScrollOffsetAfterZoom()
        resetPlaybackFollow()
        
        let zoomPercentage = Int(round(newScale * 100))
        showToast(message: "缩放: \(zoomPercentage)%")
        
        DispatchQueue.main.async {
            self.isZooming = false
        }
    }
    
    func scrollWaveform(delta: CGFloat) {
        isScrolling = true
        let newOffset = waveformScrollOffset + delta
        setWaveformScrollOffset(newOffset)
        resetPlaybackFollow()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.isScrolling = false
        }
    }
    
    private func adjustScrollOffsetAfterZoom() {
        let actualWaveformWidth = calculateActualWaveformWidth()
        let maxScrollOffset = max(0, actualWaveformWidth - waveformWidth)
        waveformScrollOffset = max(0, min(maxScrollOffset, waveformScrollOffset))
        
        if waveformScale <= minZoomScale + 0.0001 {
            waveformScrollOffset = 0.0
        }
    }
    
    // MARK: - Playback Follow
    
    func updatePlaybackFollow() {
        guard followPlayback && waveformScale > minZoomScale && duration > 0 && !isScrollbarDragging && !isAnimatingSeek else {
            return
        }
        
        let progress = CGFloat(currentTime / duration)
        let actualWaveformWidth = calculateActualWaveformWidth()
        let playbackPositionInWaveform = progress * actualWaveformWidth
        let playbackPositionInWindow = playbackPositionInWaveform - waveformScrollOffset
        let windowCenter = waveformWidth / 2
        
        if playbackPositionInWindow < 0 || playbackPositionInWindow > waveformWidth {
            let targetScrollOffset = playbackPositionInWaveform - windowCenter
            setWaveformScrollOffset(targetScrollOffset)
            isPlaybackCentered = true
        } else if abs(playbackPositionInWindow - windowCenter) <= 1 {
            let targetScrollOffset = playbackPositionInWaveform - windowCenter
            setWaveformScrollOffset(targetScrollOffset)
            isPlaybackCentered = true
        } else {
            isPlaybackCentered = false
        }
    }
    
    func resetPlaybackFollow() {
        isPlaybackCentered = false
        playbackFollowTimer?.invalidate()
        playbackFollowTimer = nil
    }
    
    // 公共：计算实际波形宽度（供视图使用）
    func calculateActualWaveformWidth() -> CGFloat {
        guard duration > 0 else { return waveformWidth }
        let minWidth = CGFloat(duration) * minPxPerSec
        let baseWidth = max(waveformWidth, minWidth)
        return baseWidth * waveformScale
    }
    
    // 公共：是否需要滚动条
    var isWaveformScrollable: Bool {
        calculateActualWaveformWidth() > waveformWidth + 0.5
    }
    
    // 删除选中的自动化控制点
    func deleteSelectedAutomationPoint() {
        volumeAutomation.deleteSelectedPoint()
    }
}

