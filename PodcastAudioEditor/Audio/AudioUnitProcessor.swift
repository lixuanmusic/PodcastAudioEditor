import AVFoundation
import AudioUnit

// AudioUnit音频处理器：使用AU框架实现实时音频效果
class AudioUnitProcessor: ObservableObject {
    @Published var isEnabled = false
    @Published var currentGainDB: Float = 0.0
    
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var file: AVAudioFile?
    private var gainUnit: AVAudioUnitEQ?
    private var currentTime: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var timer: Timer?
    private var gains: [Float] = []
    private var hopSize: Int = 768
    private var sampleRate: Double = 44100
    
    // 初始化AudioUnit效果器
    func setupAudioEngine(fileURL: URL) throws {
        stop()
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        audioPlayerNode = AVAudioPlayerNode()
        guard let playerNode = audioPlayerNode else { return }
        
        // 加载音频文件
        file = try AVAudioFile(forReading: fileURL)
        guard let audioFile = file else { return }
        
        let format = audioFile.processingFormat
        sampleRate = format.sampleRate
        duration = Double(audioFile.length) / sampleRate
        
        // 创建EQ作为增益控制（使用Parametric EQ的1个频段作为全局增益）
        let eqUnit = AVAudioUnitEQ(numberOfBands: 1)
        gainUnit = eqUnit
        
        // 配置EQ频段为全频段增益
        let band = eqUnit.bands[0]
        band.frequency = 1000.0  // 中心频率
        band.bandwidth = 1.0     // 带宽（Q值）
        band.gain = 0.0          // 增益（初始为0）
        band.bypass = false
        
        // 连接音频节点：PlayerNode -> EQ -> Output
        engine.attach(playerNode)
        engine.attach(eqUnit)
        
        engine.connect(playerNode, to: eqUnit, format: format)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: format)
        
        try engine.start()
        
        print("✓ AudioEngine设置完成，使用EQ作为增益控制")
    }
    
    // 设置增益数组
    func setGains(_ gains: [Float], hopSize: Int = 768) {
        self.gains = gains
        self.hopSize = hopSize
        updateGain(for: currentTime)
    }
    
    // 根据播放时间更新增益
    private func updateGain(for time: TimeInterval) {
        guard let eqUnit = gainUnit else { return }
        
        if !isEnabled || gains.isEmpty {
            // 如果未启用，增益设为0
            eqUnit.bands[0].gain = 0.0
            DispatchQueue.main.async {
                self.currentGainDB = 0.0
            }
            return
        }
        
        // 计算对应的帧索引
        let sampleIdx = Int(time * sampleRate)
        let frameIdx = sampleIdx / hopSize
        let gainIdx = min(frameIdx, gains.count - 1)
        
        let gainDB = gains[gainIdx]
        
        // 应用增益到EQ频段
        eqUnit.bands[0].gain = gainDB
        
        DispatchQueue.main.async {
            self.currentGainDB = gainDB
        }
    }
    
    // 播放音频
    func play() {
        guard let playerNode = audioPlayerNode,
              let audioFile = file,
              let engine = audioEngine,
              engine.isRunning else {
            print("⚠️ AudioEngine未准备好")
            return
        }
        
        // 停止之前的播放
        playerNode.stop()
        currentTime = 0
        
        // 调度播放
        playerNode.scheduleFile(audioFile, at: nil) {
            DispatchQueue.main.async {
                self.stop()
            }
        }
        
        playerNode.play()
        
        // 启动定时器更新增益
        startTimer()
        
        print("▶️ 开始播放（AudioEngine）")
    }
    
    // 暂停播放
    func pause() {
        audioPlayerNode?.pause()
        
        // 保存当前时间
        if let start = startTime {
            let elapsed = Date().timeIntervalSince(start)
            pausedTime += elapsed
            startTime = nil
        }
        
        stopTimer()
        print("⏸️ 暂停播放")
    }
    
    // 停止播放
    func stop() {
        audioPlayerNode?.stop()
        currentTime = 0
        pausedTime = 0
        startTime = nil
        stopTimer()
        
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        
        print("⏹️ 停止播放")
    }
    
    // 跳转到指定时间
    func seek(to time: TimeInterval) {
        guard let playerNode = audioPlayerNode,
              let audioFile = file else { return }
        
        let wasPlaying = playerNode.isPlaying
        
        playerNode.stop()
        
        // 计算帧位置
        let sampleRate = audioFile.processingFormat.sampleRate
        let framePosition = AVAudioFramePosition(time * sampleRate)
        audioFile.framePosition = framePosition
        
        currentTime = time
        pausedTime = time
        startTime = nil
        
        if wasPlaying {
            playerNode.scheduleFile(audioFile, at: nil) {
                DispatchQueue.main.async {
                    self.stop()
                }
            }
            playerNode.play()
            startTimer()
        } else {
            updateGain(for: time)
        }
        
        print("⏩ 跳转到 \(String(format: "%.2f", time))s")
    }
    
    // 启用/禁用效果器
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            gainUnit?.bands[0].gain = 0.0
            currentGainDB = 0
        } else {
            updateGain(for: currentTime)
        }
        print("🔊 音量动态平衡: \(enabled ? "启用" : "禁用")")
    }
    
    // 获取当前播放时间
    func getCurrentTime() -> TimeInterval {
        return currentTime
    }
    
    // 获取音频时长
    func getDuration() -> TimeInterval {
        return duration
    }
    
    // 设置音量（主音量控制）
    func setVolume(_ volume: Float) {
        guard let engine = audioEngine else { return }
        engine.mainMixerNode.volume = volume
    }
    
    // MARK: - Timer
    
    private var startTime: Date?
    private var pausedTime: TimeInterval = 0
    
    private func startTimer() {
        stopTimer()
        
        if startTime == nil {
            startTime = Date()
            pausedTime = currentTime
        }
        
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if let start = self.startTime {
                let elapsed = Date().timeIntervalSince(start)
                self.currentTime = self.pausedTime + elapsed
                
                if self.currentTime >= self.duration {
                    self.stop()
                } else {
                    self.updateGain(for: self.currentTime)
                }
                
                DispatchQueue.main.async {
                    // currentTime已经更新，这里只是触发UI更新
                }
            }
        }
        
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

