import AVFoundation
import AudioUnit
import Accelerate

// Audio Unit 实时音量动态平衡处理器
class AudioUnitProcessor {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var format: AVAudioFormat?
    
    private var gains: [Float] = []
    private var hopSize: Int = 768
    private var sampleRate: Double = 44100
    
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 0.9 {
        didSet {
            playerNode?.volume = volume
        }
    }
    
    var onTimeUpdate: ((TimeInterval) -> Void)?
    
    // 加载音频文件
    func loadFile(url: URL) throws {
        stop()
        
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            throw NSError(domain: "AudioUnitProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法读取音频文件"])
        }
        
        self.audioFile = audioFile
        self.format = audioFile.processingFormat
        self.sampleRate = audioFile.processingFormat.sampleRate
        self.duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        
        // 创建音频引擎
        setupAudioEngine()
        
        print("✓ AudioUnit 加载成功: \(url.lastPathComponent), 时长: \(duration)s")
    }
    
    // 设置音频引擎和效果链
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine,
              let format = format,
              let file = audioFile else { return }
        
        // 创建播放节点
        playerNode = AVAudioPlayerNode()
        engine.attach(playerNode!)
        
        // 连接节点：Player -> MainMixer
        engine.connect(playerNode!, to: engine.mainMixerNode, format: format)
        
        // 配置引擎
        engine.prepare()
        
        print("✓ AudioEngine 设置完成")
    }
    
    // 启用音量动态平衡效果
    func enableVolumeBalance(gains: [Float], hopSize: Int = 768) {
        self.gains = gains
        self.hopSize = hopSize
        
        guard let engine = audioEngine,
              let playerNode = playerNode,
              let format = format,
              let file = audioFile else {
            print("⚠️ 音频未加载，无法启用效果")
            return
        }
        
        // 断开现有连接
        engine.disconnectNodeInput(engine.mainMixerNode)
        
        // 创建自定义效果节点（使用 AVAudioUnitTap 实现）
        let effectNode = AVAudioMixerNode()
        engine.attach(effectNode)
        
        // 连接：Player -> Effect -> MainMixer
        engine.connect(playerNode, to: effectNode, format: format)
        engine.connect(effectNode, to: engine.mainMixerNode, format: format)
        
        // 在效果节点上安装 tap 来实时应用增益
        let bufferSize: AVAudioFrameCount = 512
        
        effectNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            guard let self = self, !self.gains.isEmpty else { return }
            
            // 计算当前播放时间（基于时间戳）
            let sampleTime = time.sampleTime
            let currentTime = Double(sampleTime) / time.sampleRate
            self.currentTime = currentTime
            DispatchQueue.main.async {
                self.onTimeUpdate?(currentTime)
            }
            
            // 应用增益到缓冲区
            self.applyGain(to: buffer, at: sampleTime)
        }
        
        engine.prepare()
        print("✓ 音量动态平衡已启用")
    }
    
    // 禁用音量动态平衡
    func disableVolumeBalance() {
        guard let engine = audioEngine,
              let effectNode = engine.attachedNodes.first(where: { $0 is AVAudioMixerNode && $0 !== engine.mainMixerNode }) as? AVAudioMixerNode else {
            return
        }
        
        // 移除 tap
        effectNode.removeTap(onBus: 0)
        
        // 重新连接：Player -> MainMixer（直连）
        engine.disconnectNodeInput(engine.mainMixerNode)
        guard let playerNode = playerNode,
              let format = format else { return }
        
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        gains.removeAll()
        print("✓ 音量动态平衡已禁用")
    }
    
    // 应用增益到音频缓冲区
    private func applyGain(to buffer: AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition) {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }
        
        // 计算当前帧索引
        let currentSampleTime = Int(sampleTime)
        let currentFrameIdx = currentSampleTime / hopSize
        
        // 为每个采样点应用增益
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            
            for frame in 0..<frameLength {
                let sampleIdx = currentSampleTime + frame
                let frameIdx = sampleIdx / hopSize
                let gainIdx = min(frameIdx, gains.count - 1)
                
                // 获取增益并转换为线性值
                let gainDB = gains[gainIdx]
                let gainLinear = pow(10.0, gainDB / 20.0)
                
                // 应用增益
                samples[frame] *= gainLinear
                
                // 防止削波
                samples[frame] = max(-1.0, min(1.0, samples[frame]))
            }
        }
    }
    
    // 播放
    func play() {
        guard let engine = audioEngine,
              let playerNode = playerNode,
              let file = audioFile else {
            print("⚠️ 音频未加载")
            return
        }
        
        do {
            if !engine.isRunning {
                try engine.start()
            }
            
            // 调度播放
            if !isPlaying {
                playerNode.scheduleFile(file, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        self?.isPlaying = false
                        self?.currentTime = self?.duration ?? 0
                        self?.onTimeUpdate?(self?.duration ?? 0)
                    }
                }
            }
            
            playerNode.volume = volume
            playerNode.play()
            
            DispatchQueue.main.async {
                self.isPlaying = true
            }
            
            print("▶️ 开始播放 (AudioUnit)")
        } catch {
            print("❌ 播放失败: \(error.localizedDescription)")
        }
    }
    
    // 暂停
    func pause() {
        playerNode?.pause()
        DispatchQueue.main.async {
            self.isPlaying = false
        }
        print("⏸️ 暂停播放")
    }
    
    // 停止
    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
        }
        audioEngine?.reset()
        print("⏹️ 停止播放")
    }
    
    // 跳转
    func seek(to time: TimeInterval) {
        guard let engine = audioEngine,
              let playerNode = playerNode,
              let file = audioFile else { return }
        
        let wasPlaying = isPlaying
        
        playerNode.stop()
        
        // 计算目标帧位置
        let targetFrame = AVAudioFramePosition(time * sampleRate)
        file.framePosition = max(0, min(targetFrame, file.length))
        
        // 重新调度
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.currentTime = self?.duration ?? 0
                self?.onTimeUpdate?(self?.duration ?? 0)
            }
        }
        
        DispatchQueue.main.async {
            self.currentTime = time
            self.onTimeUpdate?(time)
        }
        
        if wasPlaying {
            playerNode.play()
        }
        
        print("⏩ 跳转到 \(time)s")
    }
    
    // 设置音量
    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        playerNode?.volume = volume
    }
}

