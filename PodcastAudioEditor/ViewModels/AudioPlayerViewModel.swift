import SwiftUI
import Combine

class AudioPlayerViewModel: ObservableObject {
    @Published var audioEngine = AudioEngine.shared
    
    // 播放状态
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var hasAudioFile: Bool = false
    
    // 波形缩放相关（参考 Miniwave）
    @Published var waveformScale: CGFloat = 1.0
    @Published var waveformScrollOffset: CGFloat = 0.0
    @Published var waveformWidth: CGFloat = 800
    
    private let minZoomScale: CGFloat = 1.0
    private let maxZoomScale: CGFloat = 20.0
    
    // 缩放状态标记
    @Published var isZooming: Bool = false
    @Published var isScrolling: Bool = false
    
    // DAW风格播放条跟随
    @Published var followPlayback: Bool = true
    @Published var isPlaybackCentered: Bool = false
    @Published var isScrollbarDragging: Bool = false
    @Published var isAnimatingSeek: Bool = false
    
    private var playbackFollowTimer: Timer?
    private var seekAnimationTimer: Timer?
    private var isWaitingForFollow: Bool = false
    private var lastPlaybackPosition: CGFloat = 0
    
    // Toast 提示
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    private var toastTimer: Timer?
    
    private var cancellables: Set<AnyCancellable> = []
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        // 绑定播放状态
        audioEngine.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                self?.isPlaying = isPlaying
            }
            .store(in: &cancellables)
        
        // 绑定时间
        audioEngine.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
            }
            .store(in: &cancellables)
        
        // 绑定时长
        audioEngine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.duration = duration
                if duration > 0 {
                    self?.hasAudioFile = true
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 播放控制
    
    func togglePlayPause() {
        if isPlaying {
            audioEngine.pause()
        } else {
            audioEngine.play()
        }
    }
    
    func seekToBeginning() {
        audioEngine.seek(to: 0)
        showToast(message: "回到开头")
    }
    
    // MARK: - 波形缩放（参考 Miniwave）
    
    func zoomWaveformAtPoint(delta: CGFloat, mouseX: CGFloat, waveformWidth: CGFloat) {
        let zoomFactor = delta > 0 ? 1.1 : 0.9
        let newScale = max(minZoomScale, min(maxZoomScale, waveformScale * zoomFactor))
        
        guard newScale != waveformScale else {
            if waveformScale >= maxZoomScale && delta > 0 {
                showToast(message: "已达到最大缩放")
            } else if waveformScale <= minZoomScale && delta < 0 {
                showToast(message: "已达到最小缩放")
            }
            return
        }
        
        isZooming = true
        
        // 计算鼠标位置对应的波形位置百分比
        let oldActualWidth = calculateActualWaveformWidth()
        let mousePositionInWaveformRatio = (mouseX + waveformScrollOffset) / oldActualWidth
        
        withAnimation(.none) {
            waveformScale = newScale
            
            // 重新计算 scrollOffset 以保持鼠标位置不变
            let newActualWidth = calculateActualWaveformWidth()
            let newMousePositionInWaveform = mousePositionInWaveformRatio * newActualWidth
            let newScrollOffset = newMousePositionInWaveform - mouseX
            setWaveformScrollOffset(newScrollOffset)
        }
        
        adjustScrollOffsetAfterZoom()
        resetPlaybackFollow()
        
        let zoomPercentage = Int(round(newScale * 100))
        showToast(message: "缩放: \(zoomPercentage)%")
        
        DispatchQueue.main.async {
            self.isZooming = false
        }
    }
    
    func resetWaveformZoom() {
        waveformScale = 1.0
        waveformScrollOffset = 0.0
        showToast(message: "重置缩放")
    }
    
    func scrollWaveform(delta: CGFloat) {
        isScrolling = true
        let newOffset = waveformScrollOffset + delta
        setWaveformScrollOffset(newOffset)
        resetPlaybackFollow()
        
        // 延长 isScrolling 的持续时间，确保滚动动作完全完成后再启用动画
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.isScrolling = false
        }
    }
    
    // WaveSurfer 逻辑：基于音频时长和窗口宽度计算实际波形宽度
    private func calculateActualWaveformWidth() -> CGFloat {
        guard duration > 0 else { return waveformWidth }
        
        // minPxPerSec 是最小像素密度，如果窗口更宽则填满窗口
        let minPxPerSec: CGFloat = 50.0
        let minWidth = CGFloat(duration) * minPxPerSec
        
        // scale=1.0 时，波形填满窗口（或使用最小宽度，取较大值）
        let baseWidth = max(waveformWidth, minWidth)
        
        // 应用缩放因子
        let result = baseWidth * waveformScale
        
        // Debug 输出
        print("📊 波形宽度计算: duration=\(duration)s, windowWidth=\(waveformWidth), minWidth=\(minWidth), baseWidth=\(baseWidth), scale=\(waveformScale), result=\(result)")
        
        return result
    }
    
    func setWaveformScrollOffset(_ offset: CGFloat) {
        let actualWaveformWidth = calculateActualWaveformWidth()
        let maxScrollOffset = max(0, actualWaveformWidth - waveformWidth)
        waveformScrollOffset = max(0, min(maxScrollOffset, offset))
    }
    
    private func adjustScrollOffsetAfterZoom() {
        let actualWaveformWidth = calculateActualWaveformWidth()
        let maxScrollOffset = max(0, actualWaveformWidth - waveformWidth)
        waveformScrollOffset = max(0, min(maxScrollOffset, waveformScrollOffset))
        
        if waveformScale <= 1.0 {
            waveformScrollOffset = 0.0
        }
    }
    
    func updateWaveformWidth(_ width: CGFloat) {
        waveformWidth = width
    }
    
    // MARK: - 播放条跟随（参考 Miniwave）
    
    func updatePlaybackFollow() {
        guard followPlayback && waveformScale > 1.0 && duration > 0 && !isScrollbarDragging && !isAnimatingSeek else {
            return
        }
        
        let progress = CGFloat(currentTime / duration)
        let actualWaveformWidth = calculateActualWaveformWidth()
        let playbackPositionInWaveform = progress * actualWaveformWidth
        let playbackPositionInWindow = playbackPositionInWaveform - waveformScrollOffset
        let windowCenter = waveformWidth / 2
        
        if playbackPositionInWindow < 0 {
            if !isWaitingForFollow && !isPlaybackCentered {
                startPlaybackFollowDelay()
            }
        } else if playbackPositionInWindow < windowCenter {
            if playbackPositionInWindow >= windowCenter - 1 {
                let targetScrollOffset = playbackPositionInWaveform - windowCenter
                setWaveformScrollOffset(targetScrollOffset)
                isPlaybackCentered = true
                cancelPlaybackFollowDelay()
            }
        } else if playbackPositionInWindow > windowCenter {
            if !isWaitingForFollow && !isPlaybackCentered {
                startPlaybackFollowDelay()
            }
        }
        
        if isPlaybackCentered {
            let targetScrollOffset = playbackPositionInWaveform - windowCenter
            setWaveformScrollOffset(targetScrollOffset)
        }
        
        lastPlaybackPosition = playbackPositionInWindow
    }
    
    private func startPlaybackFollowDelay() {
        isWaitingForFollow = true
        playbackFollowTimer?.invalidate()
        
        playbackFollowTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            DispatchQueue.main.async {
                self.executePlaybackFollow()
            }
        }
    }
    
    private func cancelPlaybackFollowDelay() {
        isWaitingForFollow = false
        playbackFollowTimer?.invalidate()
        playbackFollowTimer = nil
    }
    
    private func executePlaybackFollow() {
        guard isWaitingForFollow else { return }
        
        let progress = CGFloat(currentTime / duration)
        let totalScaledWidth = waveformWidth * waveformScale
        let playbackPositionInWaveform = progress * totalScaledWidth
        let windowCenter = waveformWidth / 2
        let targetScrollOffset = playbackPositionInWaveform - windowCenter
        
        withAnimation(.easeInOut(duration: 0.3)) {
            setWaveformScrollOffset(targetScrollOffset)
        }
        
        isPlaybackCentered = true
        isWaitingForFollow = false
        playbackFollowTimer = nil
    }
    
    func resetPlaybackFollow() {
        isPlaybackCentered = false
        lastPlaybackPosition = 0
        cancelPlaybackFollowDelay()
    }
    
    // MARK: - Toast 提示
    
    private func showToast(message: String) {
        toastTimer?.invalidate()
        toastMessage = message
        showToast = true
        
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            DispatchQueue.main.async {
                self.showToast = false
            }
        }
    }
    
    deinit {
        toastTimer?.invalidate()
        playbackFollowTimer?.invalidate()
        seekAnimationTimer?.invalidate()
    }
}

