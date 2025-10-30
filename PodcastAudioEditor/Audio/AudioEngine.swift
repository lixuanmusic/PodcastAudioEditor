import AVFoundation
import Foundation
import Combine

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
    
    // 统一的音频引擎
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var format: AVAudioFormat?
    
    // 音量平衡效果器
    private var eqUnit: AVAudioUnitEQ?
    private var gains: [Float] = []
    private var hopSize: Int = 768
    private var sampleRate: Double = 44100
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 0.9
    @Published var waveformData: [[Float]] = [] // 多声道波形数据
    @Published var currentGainDB: Float = 0.0  // 当前AU增益值（用于UI显示）
    @Published var volumeBalanceEnabled = false
    
    private var timer: Timer?
    private var waveformConfig = WaveformProcessingConfig()
    private var currentFileURL: URL?
    private var scheduledStartTime: AVAudioTime?
    
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
        
        do {
            // 统一使用AVAudioEngine
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            
            // 加载音频文件
            let file = try AVAudioFile(forReading: url)
            format = file.processingFormat
            sampleRate = format?.sampleRate ?? 44100
            duration = Double(file.length) / sampleRate
            
            // 设置音频节点
            engine.attach(playerNode)
            
            // 如果需要音量平衡，添加EQ效果器
            if volumeBalanceEnabled && !gains.isEmpty {
                let eq = AVAudioUnitEQ(numberOfBands: 1)
                eq.bands[0].frequency = 1000.0
                eq.bands[0].bandwidth = 1.0
                eq.bands[0].gain = 0.0
                eq.bands[0].bypass = false
                engine.attach(eq)
                eqUnit = eq
                
                // 连接：PlayerNode -> EQ -> Output
                engine.connect(playerNode, to: eq, format: format)
                engine.connect(eq, to: engine.mainMixerNode, format: format)
            } else {
                // 连接：PlayerNode -> Output
                engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                eqUnit = nil
            }
            
            // 设置音量
            engine.mainMixerNode.volume = volume
            
            // 启动引擎
            try engine.start()
            
            self.audioEngine = engine
            self.playerNode = playerNode
            self.audioFile = file
            
            DispatchQueue.main.async {
                self.isPlaying = false
                self.currentTime = 0
                print("✓ 音频加载成功: \(url.lastPathComponent), 时长: \(String(format: "%.2f", self.duration))s")
            }
        } catch {
            print("❌ 音频加载失败: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.duration = 0
                self.isPlaying = false
                self.currentTime = 0
            }
        }
        
        // 异步生成波形数据
        extractWaveformData(from: url)
    }
    
    // 设置音量平衡增益数组
    func setVolumeBalanceGains(_ gains: [Float], hopSize: Int = 768) {
        self.gains = gains
        self.hopSize = hopSize
        
        // 如果效果器已启用，更新当前增益
        if volumeBalanceEnabled {
            updateGain(for: currentTime)
        }
        
        // 如果文件已加载且效果器已启用，需要重新连接以应用效果器
        if let engine = audioEngine,
           let playerNode = playerNode,
           let format = format,
           volumeBalanceEnabled,
           !gains.isEmpty,
           eqUnit == nil {
            // 效果器未添加，需要添加
            let wasPlaying = isPlaying
            let savedTime = currentTime
            
            playerNode.stop()
            
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            eq.bands[0].frequency = 1000.0
            eq.bands[0].bandwidth = 1.0
            eq.bands[0].gain = 0.0
            eq.bands[0].bypass = false
            engine.attach(eq)
            eqUnit = eq
            
            // 断开现有连接
            engine.disconnectNodeInput(playerNode)
            
            // 连接：PlayerNode -> EQ -> Output
            engine.connect(playerNode, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            
            updateGain(for: savedTime)
            
            // 恢复文件位置
            if let audioFile = audioFile {
                let framePosition = AVAudioFramePosition(savedTime * sampleRate)
                audioFile.framePosition = framePosition
                
                DispatchQueue.main.async {
                    self.currentTime = savedTime
                    
                    if wasPlaying {
                        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                            DispatchQueue.main.async {
                                self?.stop()
                            }
                        }
                        playerNode.play()
                        self.scheduledStartTime = engine.outputNode.lastRenderTime
                        self.isPlaying = true
                        self.startTimer()
                    }
                }
            }
        }
    }
    
    // 启用/禁用音量平衡效果器
    func setVolumeBalanceEnabled(_ enabled: Bool) {
        guard volumeBalanceEnabled != enabled else { return }
        
        guard let engine = audioEngine,
              let playerNode = playerNode,
              let audioFile = audioFile,
              let format = format else {
            // 如果文件未加载，只更新状态
            volumeBalanceEnabled = enabled
            return
        }
        
        let wasPlaying = isPlaying
        let savedTime = currentTime
        
        // 停止当前播放
        playerNode.stop()
        
        // 移除现有连接
        engine.disconnectNodeInput(playerNode)
        if let eq = eqUnit {
            engine.disconnectNodeInput(eq)
            engine.detach(eq)
        }
        
        volumeBalanceEnabled = enabled
        
        // 如果需要音量平衡且有增益数据，添加EQ效果器
        if enabled && !gains.isEmpty {
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            eq.bands[0].frequency = 1000.0
            eq.bands[0].bandwidth = 1.0
            eq.bands[0].gain = 0.0
            eq.bands[0].bypass = false
            engine.attach(eq)
            eqUnit = eq
            
            // 连接：PlayerNode -> EQ -> Output
            engine.connect(playerNode, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            
            // 更新当前增益
            updateGain(for: savedTime)
        } else {
            // 连接：PlayerNode -> Output
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            eqUnit = nil
            currentGainDB = 0.0
        }
        
        // 恢复文件位置和播放状态
        let framePosition = AVAudioFramePosition(savedTime * sampleRate)
        audioFile.framePosition = framePosition
        
        DispatchQueue.main.async {
            self.currentTime = savedTime
            
            if wasPlaying {
                // 重新调度播放
                playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        self?.stop()
                    }
                }
                
                playerNode.play()
                self.scheduledStartTime = engine.outputNode.lastRenderTime
                self.isPlaying = true
                self.startTimer()
            }
        }
        
        print("🔊 音量动态平衡: \(enabled ? "启用" : "禁用")")
    }
    
    func play() {
        guard let playerNode = playerNode,
              let audioFile = audioFile,
              let engine = audioEngine,
              engine.isRunning else {
            print("⚠️ 未加载音频文件或引擎未启动")
            return
        }
        
        // 如果已经在播放，不做任何操作
        if isPlaying && playerNode.isPlaying {
            return
        }
        
        // 停止之前的播放，确保没有重复调度
        if playerNode.isPlaying || scheduledStartTime != nil {
            playerNode.stop()
        }
        
        // 等待节点完全停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self = self,
                  let playerNode = self.playerNode,
                  let audioFile = self.audioFile,
                  let engine = self.audioEngine else { return }
            
            // 设置文件位置
            let framePosition = AVAudioFramePosition(self.currentTime * self.sampleRate)
            audioFile.framePosition = framePosition
            
            // 调度播放
            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.stop()
                }
            }
            
            playerNode.play()
            
            self.scheduledStartTime = engine.outputNode.lastRenderTime
            self.isPlaying = true
            self.startTimer()
            
            print("▶️ 开始播放")
        }
    }
    
    func pause() {
        guard let playerNode = playerNode else { return }
        
        // 保存当前播放时间
        if let startTime = scheduledStartTime,
           let engine = audioEngine,
           let playerTime = playerNode.playerTime(forNodeTime: engine.outputNode.lastRenderTime ?? AVAudioTime()) {
            let elapsed = Double(playerTime.sampleTime) / sampleRate
            currentTime = max(0, min(duration, currentTime + elapsed))
        }
        
        playerNode.pause()
        
        DispatchQueue.main.async {
            self.isPlaying = false
            self.stopTimer()
            self.scheduledStartTime = nil
        }
        
        print("⏸️ 暂停播放")
    }
    
    func stop() {
        guard let playerNode = playerNode else { return }
        
        playerNode.stop()
        audioFile?.framePosition = 0
        
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
            self.scheduledStartTime = nil
        }
        
        print("⏹️ 停止播放")
    }
    
    func seek(to time: TimeInterval) {
        guard let playerNode = playerNode,
              let audioFile = audioFile else { return }
        
        let wasPlaying = isPlaying
        let clampedTime = max(0, min(duration, time))
        
        // 必须停止播放，避免重复调度
        playerNode.stop()
        
        // 等待节点完全停止
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self = self,
                  let playerNode = self.playerNode,
                  let audioFile = self.audioFile else { return }
            
            // 设置文件位置
            let framePosition = AVAudioFramePosition(clampedTime * self.sampleRate)
            audioFile.framePosition = framePosition
            
            self.currentTime = clampedTime
            self.updateGain(for: clampedTime)
            
            // 如果之前在播放，继续播放
            if wasPlaying {
                playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        self?.stop()
                    }
                }
                
                if let engine = self.audioEngine {
                    self.scheduledStartTime = engine.outputNode.lastRenderTime
                }
                
                playerNode.play()
                self.isPlaying = true
                self.startTimer()
            }
        }
        
        print("⏩ 跳转到 \(String(format: "%.2f", clampedTime))s")
    }
    
    func setVolume(_ value: Float) {
        volume = max(0, min(value, 1))
        audioEngine?.mainMixerNode.volume = volume
    }
    
    // 更新当前时间的增益
    private func updateGain(for time: TimeInterval) {
        guard volumeBalanceEnabled, let eqUnit = eqUnit, !gains.isEmpty else {
            currentGainDB = 0.0
            return
        }
        
        // 计算对应的帧索引
        let sampleIdx = Int(time * sampleRate)
        let frameIdx = sampleIdx / hopSize
        let gainIdx = min(frameIdx, gains.count - 1)
        
        let gainDB = gains[gainIdx]
        
        // 应用增益到EQ频段
        eqUnit.bands[0].gain = gainDB
        currentGainDB = gainDB
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
        guard let playerNode = playerNode,
              let engine = audioEngine,
              isPlaying else { return }
        
        // 计算当前播放时间
        if let startTime = scheduledStartTime,
           let playerTime = playerNode.playerTime(forNodeTime: engine.outputNode.lastRenderTime ?? AVAudioTime()) {
            let elapsed = Double(playerTime.sampleTime) / sampleRate
            let newTime = max(0, min(duration, currentTime + elapsed))
            
            DispatchQueue.main.async {
                self.currentTime = newTime
                self.updateGain(for: newTime)
                
                // 检查是否播放完成
                if newTime >= self.duration {
                    self.stop()
                }
            }
        } else {
            // 如果无法获取精确时间，使用简单累加
            DispatchQueue.main.async {
                let newTime = self.currentTime + 1.0 / 60.0
                if newTime >= self.duration {
                    self.stop()
                } else {
                    self.currentTime = newTime
                    self.updateGain(for: newTime)
                }
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

