import AVFoundation
import Accelerate

// 音频处理配置
struct AudioProcessingConfig {
    var volumeBalanceEnabled: Bool = false
    var targetLUFS: Float = -16.0  // 目标响度（LUFS）
    var maxGainDB: Float = 12.0    // 最大增益（dB）
    var minGainDB: Float = -12.0   // 最小增益（dB）
    var smoothingWindow: Int = 100 // 平滑窗口（帧数）
}

// 音频处理器：负责各种音频优化处理
class AudioProcessor: ObservableObject {
    @Published var config = AudioProcessingConfig()
    @Published var isProcessing = false
    
    // 根据声学特征计算音量调节增益
    func calculateVolumeGains(features: [AcousticFeatures]) -> [Float] {
        guard !features.isEmpty else { return [] }
        
        var gains: [Float] = []
        gains.reserveCapacity(features.count)
        
        // 计算每帧的目标增益
        for feature in features {
            let gain: Float
            
            // 静音段保持原样
            if !feature.isVoiced {
                gain = 0.0
            } else {
                // 将能量（dB）转换为增益
                // 目标：使响度接近 -16 LUFS
                // 简化：假设能量 dB 与 LUFS 成正比关系
                let currentLoudness = feature.energy
                let targetLoudness = config.targetLUFS
                
                // 计算需要的增益
                var calculatedGain = targetLoudness - currentLoudness
                
                // 限制在范围内
                calculatedGain = max(config.minGainDB, min(config.maxGainDB, calculatedGain))
                
                gain = calculatedGain
            }
            
            gains.append(gain)
        }
        
        // 平滑增益曲线（避免突变）
        let smoothedGains = smoothGains(gains, windowSize: config.smoothingWindow)
        
        return smoothedGains
    }
    
    // 平滑增益曲线
    private func smoothGains(_ gains: [Float], windowSize: Int) -> [Float] {
        guard gains.count > windowSize else { return gains }
        
        var smoothed: [Float] = []
        smoothed.reserveCapacity(gains.count)
        
        let halfWindow = windowSize / 2
        
        for i in 0..<gains.count {
            let startIdx = max(0, i - halfWindow)
            let endIdx = min(gains.count, i + halfWindow + 1)
            
            var sum: Float = 0
            var count: Float = 0
            
            for j in startIdx..<endIdx {
                sum += gains[j]
                count += 1
            }
            
            smoothed.append(sum / count)
        }
        
        return smoothed
    }
    
    // 应用音量调节到音频文件
    func processAudioFile(
        inputURL: URL,
        outputURL: URL,
        gains: [Float],
        hopSize: Int = 768,
        frameSize: Int = 1024,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let audioFile = try? AVAudioFile(forReading: inputURL) else {
            throw NSError(domain: "AudioProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法读取音频文件"])
        }
        
        let format = audioFile.processingFormat
        let totalFrames = Int(audioFile.length)
        
        // 创建输出文件
        guard let outputFile = try? AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        ) else {
            throw NSError(domain: "AudioProcessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }
        
        // 读取整个音频文件
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "AudioProcessor", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法创建缓冲区"])
        }
        
        try audioFile.read(into: buffer)
        
        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "AudioProcessor", code: -4, userInfo: [NSLocalizedDescriptionKey: "无法获取音频数据"])
        }
        
        let channelCount = Int(format.channelCount)
        let sampleCount = Int(buffer.frameLength)
        
        print("📊 开始处理音频: \(sampleCount)采样点, \(channelCount)声道")
        
        // 应用增益到每个采样点
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            
            for sampleIdx in 0..<sampleCount {
                // 计算对应的帧索引
                let frameIdx = sampleIdx / hopSize
                let gainIdx = min(frameIdx, gains.count - 1)
                
                // 获取增益（dB转线性）
                let gainDB = gains[gainIdx]
                let gainLinear = pow(10.0, gainDB / 20.0)
                
                // 应用增益
                samples[sampleIdx] *= gainLinear
                
                // 防止削波（限制在 -1.0 到 1.0）
                samples[sampleIdx] = max(-1.0, min(1.0, samples[sampleIdx]))
                
                // 进度更新
                if channel == 0 && sampleIdx % 100000 == 0 {
                    let progress = Double(sampleIdx) / Double(sampleCount)
                    onProgress(progress)
                }
            }
        }
        
        // 写入输出文件
        try outputFile.write(from: buffer)
        
        onProgress(1.0)
        print("✓ 音频处理完成")
    }
}

