import AVFoundation
import Foundation

// 波形处理配置（参考 Miniwave）
struct WaveformProcessingConfig {
    let numberOfSlices: Int
    let targetDataPoints: Int
    let smallFileThreshold: Int
    let useParallelProcessing: Bool
    
    init(numberOfSlices: Int = 10,
         targetDataPoints: Int = 2000,
         smallFileThreshold: Int = 100000,
         useParallelProcessing: Bool = true) {
        self.numberOfSlices = numberOfSlices
        self.targetDataPoints = targetDataPoints
        self.smallFileThreshold = smallFileThreshold
        self.useParallelProcessing = useParallelProcessing
    }
}

final class AudioEngine: ObservableObject {
    static let shared = AudioEngine()
    
    private var player: AVAudioPlayer?
    private var auProcessor: AudioUnitProcessor?
    private var useAUProcessor: Bool = false
    private var currentFileURL: URL?
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 0.9
    @Published var waveformData: [[Float]] = [] // 多声道波形数据
    
    private var timer: Timer?
    private var waveformConfig = WaveformProcessingConfig()
    
    private init() {
        optimizeWaveformConfig()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImportedFile(_:)),
            name: .didImportAudioFile,
            object: nil
        )
    }
    
    private func optimizeWaveformConfig() {
        let coreCount = ProcessInfo.processInfo.processorCount
        let optimalSlices = min(max(coreCount * 2, 4), 16)
        waveformConfig = WaveformProcessingConfig(
            numberOfSlices: optimalSlices,
            targetDataPoints: waveformConfig.targetDataPoints,
            smallFileThreshold: waveformConfig.smallFileThreshold,
            useParallelProcessing: waveformConfig.useParallelProcessing
        )
        print("✓ 波形处理优化 - CPU核心数: \(coreCount), 优化分片数: \(optimalSlices)")
    }
    
    @objc private func handleImportedFile(_ note: Notification) {
        guard let fileURL = note.userInfo?["url"] as? URL else { return }
        Task {
            await loadFile(url: fileURL)
        }
    }
    
    func loadFile(url: URL) async {
        stop()
        currentFileURL = url
        
        // 如果使用 AU 处理器，用 AU 加载
        if useAUProcessor {
            await loadFileWithAU(url: url)
        } else {
            await loadFileWithPlayer(url: url)
        }
        
        // 异步生成波形数据
        extractWaveformData(from: url)
    }
    
    private func loadFileWithPlayer(url: URL) async {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.isMeteringEnabled = true
            player?.volume = volume
            
            DispatchQueue.main.async {
                self.duration = self.player?.duration ?? 0
                self.isPlaying = false
                self.currentTime = 0
                print("✓ 音频加载成功 (Player): \(url.lastPathComponent), 时长: \(self.duration)s")
            }
        } catch {
            print("❌ 音频加载失败: \(error.localizedDescription)")
        }
    }
    
    private func loadFileWithAU(url: URL) async {
        let processor = AudioUnitProcessor()
        
        // 设置时间更新回调
        processor.onTimeUpdate = { [weak self] time in
            DispatchQueue.main.async {
                self?.currentTime = time
            }
        }
        
        do {
            try processor.loadFile(url: url)
            auProcessor = processor
            
            DispatchQueue.main.async {
                self.duration = processor.duration
                self.isPlaying = false
                self.currentTime = 0
                print("✓ 音频加载成功 (AU): \(url.lastPathComponent), 时长: \(processor.duration)s")
            }
        } catch {
            print("❌ AU 加载失败: \(error.localizedDescription)")
            // 回退到普通播放器
            await loadFileWithPlayer(url: url)
            useAUProcessor = false
        }
    }
    
    func play() {
        if useAUProcessor, let processor = auProcessor {
            processor.play()
            DispatchQueue.main.async {
                self.isPlaying = processor.isPlaying
            }
        } else if let player = player {
            player.play()
            DispatchQueue.main.async {
                self.isPlaying = true
                self.currentTime = player.currentTime
                self.startTimer()
            }
            print("▶️ 开始播放")
        } else {
            print("⚠️ 未加载音频文件")
        }
    }
    
    func pause() {
        if useAUProcessor {
            auProcessor?.pause()
            DispatchQueue.main.async {
                self.isPlaying = false
            }
        } else {
            player?.pause()
            DispatchQueue.main.async {
                self.isPlaying = false
                self.stopTimer()
            }
        }
        print("⏸️ 暂停播放")
    }
    
    func stop() {
        if useAUProcessor {
            auProcessor?.stop()
            DispatchQueue.main.async {
                self.isPlaying = false
                self.currentTime = 0
            }
        } else {
            player?.stop()
            player?.currentTime = 0
            DispatchQueue.main.async {
                self.isPlaying = false
                self.currentTime = 0
                self.stopTimer()
            }
        }
        print("⏹️ 停止播放")
    }
    
    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        
        if useAUProcessor, let processor = auProcessor {
            processor.seek(to: time)
            DispatchQueue.main.async {
                self.currentTime = time
                if wasPlaying {
                    self.isPlaying = processor.isPlaying
                }
            }
        } else if let player = player {
            player.pause()
            player.currentTime = time
            DispatchQueue.main.async {
                self.currentTime = time
                if wasPlaying {
                    self.play()
                } else {
                    self.updateCurrentTime()
                }
            }
        }
        print("⏩ 跳转到 \(time)s")
    }
    
    func setVolume(_ value: Float) {
        volume = max(0, min(value, 1))
        player?.volume = volume
        auProcessor?.setVolume(volume)
    }
    
    // 启用实时处理（切换到 AU 处理器）
    func enableRealtimeProcessing(gains: [Float], hopSize: Int = 768) {
        guard let fileURL = currentFileURL else {
            print("⚠️ 未加载音频文件，无法启用实时处理")
            return
        }
        
        useAUProcessor = true
        
        // 重新加载文件到 AU 处理器
        Task {
            await loadFile(url: fileURL)
            
            // 启用音量动态平衡效果
            if let processor = auProcessor {
                processor.enableVolumeBalance(gains: gains, hopSize: hopSize)
            }
        }
        
        print("✓ 已启用实时音频处理")
    }
    
    // 禁用实时处理（切换回普通播放器）
    func disableRealtimeProcessing() {
        let wasPlaying = isPlaying
        let currentPos = currentTime
        
        stop()
        useAUProcessor = false
        
        // 重新加载到普通播放器
        if let fileURL = currentFileURL {
            Task {
                await loadFile(url: fileURL)
                
                // 恢复播放位置
                if currentPos > 0 {
                    seek(to: currentPos)
                }
                
                // 如果之前在播放，继续播放
                if wasPlaying {
                    play()
                }
            }
        }
        
        print("✓ 已禁用实时音频处理")
    }
    
    // MARK: - Timer 更新
    private func startTimer() {
        stopTimer()
        // 提高更新频率到 ~60fps (16.67ms) 以获得平滑的播放条移动，特别是在高倍缩放下
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateCurrentTime()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateCurrentTime() {
        guard let player = player else { return }
        DispatchQueue.main.async {
            self.currentTime = player.currentTime
            if !player.isPlaying && self.isPlaying {
                self.isPlaying = false
                self.stopTimer()
            }
        }
    }
    
    // MARK: - 波形生成（参考 Miniwave 并行处理）
    private func extractWaveformData(from url: URL) {
        print("🌊 开始生成波形数据")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            print("❌ 无法打开音频文件用于波形生成")
            return
        }
        
        let format = audioFile.processingFormat
        let totalFrameCount = Int(audioFile.length)
        
        // 根据配置决定处理策略
        if !waveformConfig.useParallelProcessing || totalFrameCount < waveformConfig.smallFileThreshold {
            print("使用单线程波形处理")
            extractWaveformDataSingleThread(from: url, audioFile: audioFile, startTime: startTime)
        } else {
            print("使用并行波形处理")
            extractWaveformDataParallel(from: url, audioFile: audioFile, startTime: startTime)
        }
    }
    
    private func extractWaveformDataSingleThread(from url: URL, audioFile: AVAudioFile, startTime: CFAbsoluteTime) {
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("❌ 无法创建音频缓冲区")
            return
        }
        
        do {
            try audioFile.read(into: buffer)
            let sampleCount = Int(buffer.frameLength)
            let samplesPerPixel = max(sampleCount / waveformConfig.targetDataPoints, 1)
            var newWaveformData: [[Float]] = Array(repeating: [], count: Int(format.channelCount))
            
            for channel in 0..<Int(format.channelCount) {
                guard let channelData = buffer.floatChannelData?[channel] else { continue }
                for i in stride(from: 0, to: sampleCount, by: samplesPerPixel) {
                    let segment = Array(UnsafeBufferPointer(start: channelData + i, count: min(samplesPerPixel, sampleCount - i)))
                    let amplitude = segment.map { abs($0) }.max() ?? 0
                    newWaveformData[channel].append(amplitude)
                }
            }
            
            let processingTime = CFAbsoluteTimeGetCurrent() - startTime
            DispatchQueue.main.async {
                self.waveformData = newWaveformData
                print("✓ 波形生成完成 (单线程): \(newWaveformData.first?.count ?? 0)个数据点, 耗时: \(String(format: "%.3f", processingTime))秒")
            }
        } catch {
            print("❌ 读取音频失败: \(error.localizedDescription)")
        }
    }
    
    private func extractWaveformDataParallel(from url: URL, audioFile: AVAudioFile, startTime: CFAbsoluteTime) {
        let format = audioFile.processingFormat
        let totalFrameCount = Int(audioFile.length)
        let channelCount = Int(format.channelCount)
        let numberOfSlices = waveformConfig.numberOfSlices
        let framesPerSlice = totalFrameCount / numberOfSlices
        let samplesPerPixelPerSlice = max(framesPerSlice / (waveformConfig.targetDataPoints / numberOfSlices), 1)
        
        var sliceResults: [[[Float]]] = Array(repeating: Array(repeating: [], count: channelCount), count: numberOfSlices)
        let dispatchGroup = DispatchGroup()
        let resultQueue = DispatchQueue(label: "waveform.result", attributes: .concurrent)
        
        for sliceIndex in 0..<numberOfSlices {
            dispatchGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { dispatchGroup.leave() }
                do {
                    let sliceAudioFile = try AVAudioFile(forReading: url)
                    let startFrame = sliceIndex * framesPerSlice
                    let endFrame = (sliceIndex == numberOfSlices - 1) ? totalFrameCount : (startFrame + framesPerSlice)
                    let actualFrameCount = endFrame - startFrame
                    
                    sliceAudioFile.framePosition = AVAudioFramePosition(startFrame)
                    guard let sliceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(actualFrameCount)) else { return }
                    try sliceAudioFile.read(into: sliceBuffer, frameCount: UInt32(actualFrameCount))
                    
                    var sliceWaveformData: [[Float]] = Array(repeating: [], count: channelCount)
                    let sliceSampleCount = Int(sliceBuffer.frameLength)
                    
                    for channel in 0..<channelCount {
                        guard let channelData = sliceBuffer.floatChannelData?[channel] else { continue }
                        for i in stride(from: 0, to: sliceSampleCount, by: samplesPerPixelPerSlice) {
                            let segmentLength = min(samplesPerPixelPerSlice, sliceSampleCount - i)
                            let segment = Array(UnsafeBufferPointer(start: channelData + i, count: segmentLength))
                            let amplitude = segment.map { abs($0) }.max() ?? 0
                            sliceWaveformData[channel].append(amplitude)
                        }
                    }
                    
                    resultQueue.async(flags: .barrier) {
                        sliceResults[sliceIndex] = sliceWaveformData
                    }
                } catch {
                    print("❌ 片段\(sliceIndex)处理失败")
                }
            }
        }
        
        dispatchGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            var finalWaveformData: [[Float]] = Array(repeating: [], count: channelCount)
            for channel in 0..<channelCount {
                for sliceIndex in 0..<numberOfSlices {
                    finalWaveformData[channel].append(contentsOf: sliceResults[sliceIndex][channel])
                }
            }
            
            let processingTime = CFAbsoluteTimeGetCurrent() - startTime
            DispatchQueue.main.async {
                self?.waveformData = finalWaveformData
                print("✓ 波形生成完成 (并行): \(finalWaveformData.first?.count ?? 0)个数据点, 耗时: \(String(format: "%.3f", processingTime))秒")
            }
        }
    }
}

