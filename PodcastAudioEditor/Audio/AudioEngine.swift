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

    // AVAudioEngine 和播放节点
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var sampleRate: Double = 44100

    // 效果器链（4个插槽）
    @Published var effectChain = AudioEffectChain()

    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 0.9
    @Published var waveformData: [[Float]] = [] // 多声道波形数据

    private var timer: Timer?
    private var waveformConfig = WaveformProcessingConfig()
    private var hasScheduledSegment = false  // 追踪是否已调度音频段
    private var currentSegmentID = UUID()    // 当前段的唯一标识，用于取消旧段的回调
    private var currentSegmentStartFrame: AVAudioFramePosition = 0  // 当前段的起始帧

    private init() {
        optimizeWaveformConfig()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImportedFile(_:)),
            name: .didImportAudioFile,
            object: nil
        )
        // 设置效果链变更回调
        effectChain.onEffectChainChanged = { [weak self] in
            self?.reconnectEffectChain()
        }
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

        // 给旧引擎一些时间来完全清理
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        do {
            // 创建新引擎
            let newEngine = AVAudioEngine()
            let newPlayerNode = AVAudioPlayerNode()

            // 创建音频文件
            let newAudioFile = try AVAudioFile(forReading: url)
            let format = newAudioFile.processingFormat
            sampleRate = format.sampleRate

            // 附加播放器节点
            newEngine.attach(newPlayerNode)

            // 获取应该启用的效果器（考虑全局开关和插槽开关）
            let effectsToAttach: [AVAudioUnit]
            if effectChain.isEnabled {
                effectsToAttach = effectChain.getEnabledAudioUnits()
                print("📦 效果链启用，附加 \(effectsToAttach.count) 个已启用的效果器")
            } else {
                effectsToAttach = []
                print("📦 效果链禁用，不附加效果器")
            }

            // 附加效果器节点
            for unit in effectsToAttach {
                newEngine.attach(unit)
            }

            // 构建连接：PlayerNode -> Effect1 -> Effect2 -> Effect3 -> Effect4 -> MainMixer -> Output
            var previousNode: AVAudioNode = newPlayerNode

            for unit in effectsToAttach {
                newEngine.connect(previousNode, to: unit, format: format)
                previousNode = unit
            }

            // 连接最后一个节点到主混音器
            newEngine.connect(previousNode, to: newEngine.mainMixerNode, format: format)

            // 准备引擎
            try newEngine.prepare()

            // 保存引用
            self.engine = newEngine
            self.playerNode = newPlayerNode
            self.audioFile = newAudioFile
            self.hasScheduledSegment = false  // 重置调度标志

            DispatchQueue.main.async {
                self.duration = Double(newAudioFile.length) / self.sampleRate
                self.isPlaying = false
                self.currentTime = 0
                print("✓ 音频加载成功: \(url.lastPathComponent), 时长: \(String(format: "%.2f", self.duration))s")
                self.effectChain.printChainStatus()
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

        print("🎬 play() 调用 - currentTime: \(currentTime), hasScheduledSegment: \(hasScheduledSegment), isPlaying: \(isPlaying)")

        // 启动引擎
        if !engine.isRunning {
            do {
                try engine.start()
                print("✅ 引擎已启动")
            } catch {
                print("❌ 启动引擎失败: \(error.localizedDescription)")
                return
            }
        }

        // 只在没有调度过段的情况下才调度
        if !hasScheduledSegment {
            print("📅 调度音频从 \(currentTime)s 开始")
            scheduleAudioFile(at: currentTime)
            hasScheduledSegment = true
        } else {
            print("⏭️ 跳过调度（已经调度过）")
        }

        playerNode.play()

        DispatchQueue.main.async {
            self.isPlaying = true
            self.startTimer()
        }
        print("▶️ 播放节点已启动")
    }

    func pause() {
        print("⏸️ pause() 调用 - currentTime: \(currentTime)")
        playerNode?.pause()
        // 注意：暂停时不重置 hasScheduledSegment，因为段仍然有效
        // 只有 stop() 或 seek() 才需要重置调度状态
        DispatchQueue.main.async {
            self.isPlaying = false
            self.stopTimer()
        }
        print("⏸️ 暂停完成 - hasScheduledSegment保持为: \(hasScheduledSegment)")
    }

    func stop() {
        print("⏹️ stop() 调用")
        playerNode?.stop()
        engine?.stop()
        hasScheduledSegment = false  // 重置调度标志

        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
        print("⏹️ 停止完成")
    }

    func seek(to time: TimeInterval) {
        guard let playerNode = playerNode,
              let audioFile = audioFile,
              let engine = engine else { return }

        let wasPlaying = isPlaying

        // 确保时间在有效范围内
        let clampedTime = max(0, min(time, duration))

        print("🔍 seek() 调用 - 目标: \(clampedTime)s, wasPlaying: \(wasPlaying), currentTime: \(currentTime)")

        // 计算起始帧
        let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
        let totalFrames = audioFile.length - startFrame

        print("📊 起始帧: \(startFrame), 总帧数: \(totalFrames), 文件长度: \(audioFile.length)")

        guard totalFrames > 0 && startFrame >= 0 && startFrame < audioFile.length else {
            print("⚠️ 无效的seek位置: \(clampedTime)s")
            DispatchQueue.main.async {
                self.currentTime = clampedTime
            }
            return
        }

        // 停止播放节点
        playerNode.stop()
        hasScheduledSegment = false  // 重置调度标志
        currentSegmentID = UUID()     // 生成新的段ID，使旧段回调失效
        print("🛑 播放节点已停止，hasScheduledSegment重置为false，新段ID: \(currentSegmentID)")

        // 确保引擎在运行
        if !engine.isRunning {
            do {
                try engine.start()
                print("✅ 引擎已启动")
            } catch {
                print("❌ 启动引擎失败: \(error.localizedDescription)")
                return
            }
        }

        // 调度从新位置开始的音频
        let segmentID = currentSegmentID  // 捕获当前ID
        currentSegmentStartFrame = startFrame  // 保存段起始帧
        print("📅 调度新段 - 起始帧: \(startFrame), 帧数: \(totalFrames), 段ID: \(segmentID)")
        playerNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: AVAudioFrameCount(totalFrames), at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 只有当这是当前有效的段时才执行回调
                if self.currentSegmentID == segmentID && self.isPlaying {
                    print("✅ 音频段播放完成 (段ID: \(segmentID))")
                    self.stop()
                } else {
                    print("⏭️ 忽略旧段回调 (段ID: \(segmentID), 当前ID: \(self.currentSegmentID))")
                }
            }
        }
        hasScheduledSegment = true  // 标记已调度
        print("✅ 段已调度，hasScheduledSegment设置为true")

        // 立即更新 currentTime（不要异步）
        self.currentTime = clampedTime
        print("⏱️ currentTime立即更新为: \(clampedTime)s")

        if wasPlaying {
            // 恢复播放
            print("▶️ 恢复播放")
            playerNode.play()
            DispatchQueue.main.async {
                self.isPlaying = true
                self.startTimer()
            }
        } else {
            print("⏸️ 保持暂停状态")
        }

        print("⏩ seek完成 - 跳转到 \(clampedTime)s")
    }

    // 调度音频文件播放
    private func scheduleAudioFile(at startTime: TimeInterval = 0) {
        guard let playerNode = playerNode,
              let audioFile = audioFile else {
            print("⚠️ scheduleAudioFile - 没有playerNode或audioFile")
            return
        }

        // 确保时间在有效范围内
        let clampedTime = max(0, min(startTime, duration))
        let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
        let totalFrames = audioFile.length - startFrame

        print("📅 scheduleAudioFile - 开始时间: \(startTime)s, 起始帧: \(startFrame), 帧数: \(totalFrames)")

        guard totalFrames > 0 && startFrame >= 0 && startFrame < audioFile.length else {
            print("⚠️ scheduleAudioFile - 无效的seek位置: \(startTime)s")
            return
        }

        // 生成新的段ID
        currentSegmentID = UUID()
        currentSegmentStartFrame = startFrame  // 保存段起始帧
        let segmentID = currentSegmentID
        print("📅 scheduleAudioFile - 段ID: \(segmentID), 起始帧: \(startFrame)")

        // 从指定位置读取并播放
        playerNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: AVAudioFrameCount(totalFrames), at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 只有当这是当前有效的段时才执行回调
                if self.currentSegmentID == segmentID && self.isPlaying {
                    print("✅ scheduleAudioFile的段播放完成 (段ID: \(segmentID))")
                    self.stop()
                } else {
                    print("⏭️ 忽略scheduleAudioFile的旧段回调 (段ID: \(segmentID), 当前ID: \(self.currentSegmentID))")
                }
            }
        }
        print("✅ scheduleAudioFile - 段已调度")
    }

    func setVolume(_ value: Float) {
        volume = max(0, min(value, 1))
        engine?.mainMixerNode.volume = volume
    }

    // MARK: - 动态重新连接效果链
    private func reconnectEffectChain() {
        guard let playerNode = playerNode,
              let audioFile = audioFile,
              let engine = engine else {
            print("⚠️ reconnectEffectChain - 没有引擎或音频文件，跳过重连")
            return
        }

        print("🔄 开始重新连接效果链 - wasPlaying: \(isPlaying), currentTime: \(currentTime)")

        // 保存当前状态
        let wasPlaying = isPlaying
        let savedTime = currentTime

        // 停止播放节点
        playerNode.stop()
        hasScheduledSegment = false  // 重置调度标志，因为要重建整个引擎

        // 获取当前的效果器单元（在停止引擎之前）
        let currentEffects = effectChain.getEnabledAudioUnits()
        print("🔗 准备分离 \(currentEffects.count) 个效果器节点")

        // 停止并分离旧引擎中的所有节点
        if engine.isRunning {
            engine.stop()
        }

        // 关键：从旧引擎中分离所有 AudioUnit 节点
        for unit in currentEffects {
            print("🔌 从旧引擎分离效果器: \(unit)")
            engine.detach(unit)
        }

        do {
            // 创建一个新引擎并重新附加所有节点
            let newEngine = AVAudioEngine()
            let newPlayerNode = AVAudioPlayerNode()

            newEngine.attach(newPlayerNode)

            // 获取应该启用的效果器（考虑全局开关和插槽开关）
            let effectsToAttach: [AVAudioUnit]
            if effectChain.isEnabled {
                effectsToAttach = effectChain.getEnabledAudioUnits()
                print("📦 效果链启用，附加 \(effectsToAttach.count) 个已启用的效果器到新引擎")
            } else {
                effectsToAttach = []
                print("📦 效果链禁用，不附加效果器到新引擎")
            }

            // 附加效果器节点到新引擎
            for unit in effectsToAttach {
                print("🔌 附加效果器到新引擎: \(unit)")
                newEngine.attach(unit)
            }

            // 重新构建连接
            let format = audioFile.processingFormat
            var previousNode: AVAudioNode = newPlayerNode

            for unit in effectsToAttach {
                newEngine.connect(previousNode, to: unit, format: format)
                previousNode = unit
            }

            // 连接到主混音器
            newEngine.connect(previousNode, to: newEngine.mainMixerNode, format: format)

            // 准备并启动新引擎
            try newEngine.prepare()
            try newEngine.start()

            // 替换引擎
            self.engine = newEngine
            self.playerNode = newPlayerNode

            print("✓ 效果链已重新连接，引擎已启动")

            // 重新调度音频（从保存的时间位置开始）
            scheduleAudioFile(at: savedTime)
            hasScheduledSegment = true
            print("✅ 已重新调度音频从 \(savedTime)s")

            // 如果之前在播放，恢复播放
            if wasPlaying {
                print("▶️ 恢复播放")
                newPlayerNode.play()
                DispatchQueue.main.async {
                    self.isPlaying = true
                    self.startTimer()
                }
            } else {
                print("⏸️ 保持暂停状态（音频已调度）")
                DispatchQueue.main.async {
                    self.isPlaying = false
                }
            }
        } catch {
            print("❌ 重新连接效果链失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Timer 更新
    private func startTimer() {
        stopTimer()
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
            let sampleTime = Double(playerTime.sampleTime)

            guard sampleTime >= 0 else { return }

            // playerTime.sampleTime 是相对于段开始的时间
            // 加上段的起始帧来获得文件中的绝对时间
            let absoluteSampleTime = Double(currentSegmentStartFrame) + sampleTime
            let newTime = absoluteSampleTime / sampleRate

            // 确保时间在有效范围内
            let clampedTime = max(0, min(newTime, duration))

            DispatchQueue.main.async {
                self.currentTime = clampedTime

                if !playerNode.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    // MARK: - 动态音量平衡增益应用
    /// 应用增益包络到 AUPeakLimiter 的 Pre-Gain 参数
    /// - Parameters:
    ///   - gainValue: 增益值（dB）
    func applyDynamicGain(_ gainValue: Float) {
        // 获取插槽1的AUPeakLimiter效果器
        guard let slot = effectChain.getSlot(0),
              let audioUnit = slot.audioUnit else { return }

        let auAudioUnit = audioUnit.auAudioUnit

        // 查找 Pre-Gain 参数（ID 通常是 0）
        guard let parameterTree = auAudioUnit.parameterTree else { return }

        // 遍历参数找到 Pre-Gain
        if let preGainParam = parameterTree.allParameters.first(where: { param in
            param.displayName.lowercased().contains("pregain") ||
            param.displayName.lowercased().contains("pre-gain") ||
            param.displayName.lowercased().contains("input")
        }) {
            // 将 gainValue（dB）转换为参数值
            // Pre-Gain 通常以 dB 为单位，范围 -96 到 24
            let clampedGain = max(-96.0, min(24.0, gainValue))
            preGainParam.value = AUValue(clampedGain)

            print("🔊 应用增益: \(String(format: "%.2f", gainValue))dB 到 Pre-Gain")
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
