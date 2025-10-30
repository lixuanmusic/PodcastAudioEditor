import AVFoundation
import AudioToolbox
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
    
    // AVAudioEngine 相关
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var dynamicsProcessor: AVAudioUnit?
    private var audioFile: AVAudioFile?
    private var sampleRate: Double = 44100
    
    // 音量动态平衡相关
    @Published var volumeBalanceGains: [Float] = []
    private var volumeBalanceHopSize: Int = 768
    @Published var volumeBalanceEnabled: Bool = false
    @Published var currentGainDB: Float = 0.0
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 0.9
    @Published var waveformData: [[Float]] = [] // 多声道波形数据
    
    private var timer: Timer?
    private var waveformConfig = WaveformProcessingConfig()
    private var scheduleTimer: Timer?
    
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
        
        do {
            // 停止现有引擎
            engine?.stop()
            
            // 创建新引擎
            let newEngine = AVAudioEngine()
            let newPlayerNode = AVAudioPlayerNode()
            
            // 创建音频文件
            let newAudioFile = try AVAudioFile(forReading: url)
            let format = newAudioFile.processingFormat
            sampleRate = format.sampleRate
            
            // 创建 Dynamics Processor
            let componentDescription = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            
            let dynamics = AVAudioUnitEffect(audioComponentDescription: componentDescription)
            
            // 连接节点：PlayerNode -> DynamicsProcessor -> MainMixerNode -> Output
            newEngine.attach(newPlayerNode)
            newEngine.attach(dynamics)
            
            newEngine.connect(newPlayerNode, to: dynamics, format: format)
            newEngine.connect(dynamics, to: newEngine.mainMixerNode, format: format)
            
            // 配置 Dynamics Processor
            let dynamicsProc = dynamics.auAudioUnit
            
            // 设置压缩阈值为0
            if let thresholdParam = dynamicsProc.parameterTree?.parameter(withAddress: AUParameterAddress(kDynamicsProcessorParam_Threshold)) {
                thresholdParam.value = 0.0
            }
            
            // 默认旁通（稍后通过setVolumeBalanceEnabled设置）
            
            // 准备引擎
            try newEngine.prepare()
            
            // 保存引用
            self.engine = newEngine
            self.playerNode = newPlayerNode
            self.audioFile = newAudioFile
            self.dynamicsProcessor = dynamics
            
            // 初始化旁通状态（默认禁用）
            self.volumeBalanceEnabled = false
            self.currentGainDB = 0.0
            
            DispatchQueue.main.async {
                self.duration = Double(newAudioFile.length) / self.sampleRate
                self.isPlaying = false
                self.currentTime = 0
                print("✓ 音频加载成功: \(url.lastPathComponent), 时长: \(String(format: "%.2f", self.duration))s")
            }
            
            // 异步生成波形数据
            extractWaveformData(from: url)
        } catch {
            print("❌ 音频加载失败: \(error.localizedDescription)")
        }
    }
    
    func play() {
        guard let playerNode = playerNode,
              let audioFile = audioFile,
              let engine = engine else {
            print("⚠️ 未加载音频文件")
            return
        }
        
        // 启动引擎（如果未启动）
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("❌ 启动引擎失败: \(error.localizedDescription)")
                return
            }
        }
        
        // 如果未在播放，则调度音频
        if !isPlaying {
            scheduleAudioFile()
        }
        
        playerNode.play()
        
        DispatchQueue.main.async {
            self.isPlaying = true
            self.startTimer()
        }
        print("▶️ 开始播放")
    }
    
    func pause() {
        playerNode?.pause()
        DispatchQueue.main.async {
            self.isPlaying = false
            self.stopTimer()
        }
        print("⏸️ 暂停播放")
    }
    
    func stop() {
        playerNode?.stop()
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
        print("⏹️ 停止播放")
    }
    
    func seek(to time: TimeInterval) {
        guard let playerNode = playerNode,
              let audioFile = audioFile else { return }
        
        let wasPlaying = isPlaying
        playerNode.stop()
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        
        currentTime = time
        scheduleAudioFile(at: time)
        
        if wasPlaying {
            play()
        }
        
        print("⏩ 跳转到 \(time)s")
    }
    
    // 调度音频文件播放
    private func scheduleAudioFile(at startTime: TimeInterval = 0) {
        guard let playerNode = playerNode,
              let audioFile = audioFile else { return }
        
        let format = audioFile.processingFormat
        let startFrame = AVAudioFramePosition(startTime * sampleRate)
        let totalFrames = audioFile.length - startFrame
        
        guard totalFrames > 0 else { return }
        
        // 从指定位置读取并播放
        playerNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: AVAudioFrameCount(totalFrames), at: nil) { [weak self] in
            DispatchQueue.main.async {
                if let self = self, self.isPlaying {
                    self.stop()
                }
            }
        }
    }
    
    func setVolume(_ value: Float) {
        volume = max(0, min(value, 1))
        engine?.mainMixerNode.volume = volume
    }
    
    // MARK: - 音量动态平衡
    
    func setVolumeBalanceGains(_ gains: [Float], hopSize: Int) {
        volumeBalanceGains = gains
        volumeBalanceHopSize = hopSize
        print("✓ 设置音量动态平衡增益: \(gains.count)个值")
    }
    
    func setVolumeBalanceEnabled(_ enabled: Bool) {
        volumeBalanceEnabled = enabled
        
        // 设置旁通（通过设置所有参数为默认值实现旁通效果）
        // 注意：AUDynamicsProcessor没有直接的bypass属性，我们需要在播放时控制是否应用增益
        // 当enabled=false时，updateVolumeBalanceGain会设置增益为0dB（线性值为1.0）
        
        print("\(enabled ? "✓" : "✗") 音量动态平衡: \(enabled ? "启用" : "禁用")")
    }
    
    // 更新当前时间的增益
    private func updateVolumeBalanceGain(for time: TimeInterval) {
        let newGain: Float
        
        if volumeBalanceEnabled && !volumeBalanceGains.isEmpty {
            // 计算对应的帧索引
            let sampleIdx = Int(time * sampleRate)
            let frameIdx = sampleIdx / volumeBalanceHopSize
            let gainIdx = min(frameIdx, volumeBalanceGains.count - 1)
            newGain = volumeBalanceGains[gainIdx]
        } else {
            // 禁用时设置为0dB（无增益）
            newGain = 0.0
        }
        
        // 更新当前增益显示
        DispatchQueue.main.async {
            self.currentGainDB = newGain
        }
        
        // 更新 Dynamics Processor 的 Overall Gain
        if let dynamicsProc = dynamicsProcessor?.auAudioUnit,
           let overallGainParam = dynamicsProc.parameterTree?.parameter(withAddress: AUParameterAddress(kDynamicsProcessorParam_OverallGain)) {
            // dB转线性（Dynamics Processor使用线性值，范围通常是0-1或更大）
            // 注意：Overall Gain的范围可能需要调整，这里假设0dB对应某个基准值
            let linearGain = pow(10.0, Double(newGain) / 20.0)
            overallGainParam.value = Float(linearGain)
        }
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
        guard let playerNode = playerNode else { return }
        
        // 计算当前播放位置
        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            let newTime = Double(playerTime.sampleTime) / sampleRate
            DispatchQueue.main.async {
                self.currentTime = newTime
                
                // 更新音量动态平衡增益（无论是否启用，确保禁用时也设置为0dB）
                self.updateVolumeBalanceGain(for: newTime)
                
                if !playerNode.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
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

