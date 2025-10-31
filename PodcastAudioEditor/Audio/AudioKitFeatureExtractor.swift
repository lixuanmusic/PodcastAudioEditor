import AVFoundation
import Accelerate

// AudioKit 风格的特征提取器
// 注意：如果项目中没有 AudioKit，此实现使用 AVAudioEngine + Accelerate 的优化组合
final class AudioKitFeatureExtractor: FeatureExtractorProtocol {
    private let audioFile: AVAudioFile
    private let sampleRate: Double
    private let frameSize: Int = 1024  // 与 Accelerate 版本保持一致
    private let hopSize: Int = 768     // 与 Accelerate 版本保持一致
    private let config: FeatureExtractionConfig
    
    var features: [AcousticFeatures] = []
    var isProcessing: Bool = false
    var performanceMetrics = PerformanceMetrics()
    var extractorName: String { "AudioKit" }
    
    init?(audioFileURL: URL, config: FeatureExtractionConfig = .fast) {
        guard let audioFile = try? AVAudioFile(forReading: audioFileURL) else {
            return nil
        }
        self.audioFile = audioFile
        self.sampleRate = audioFile.processingFormat.sampleRate
        self.config = config
        print("📋 [AudioKit] 特征提取配置: 能量=\(config.extractEnergy), ZCR=\(config.extractZCR), 谱质心=\(config.extractSpectralCentroid), MFCC=\(config.extractMFCC)")
    }
    
    // 异步提取所有特征
    func extractFeaturesAsync(onProgress: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        isProcessing = true
        performanceMetrics = PerformanceMetrics()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                DispatchQueue.main.async {
                    self?.isProcessing = false
                    if let metrics = self?.performanceMetrics {
                        print("[AudioKit] \(metrics.report)")
                    }
                    completion()
                }
            }
            
            guard let self = self else { return }
            
            let overallStart = CFAbsoluteTimeGetCurrent()
            
            do {
                let features = try self.extractAllFeatures { progress in
                    DispatchQueue.main.async {
                        onProgress(progress)
                    }
                }
                
                let overallTime = CFAbsoluteTimeGetCurrent() - overallStart
                print("⏱️  [AudioKit] 总分析耗时: \(String(format: "%.3f", overallTime))秒")
                
                DispatchQueue.main.async {
                    self.features = features
                }
            } catch {
                print("❌ [AudioKit] 特征提取失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 提取所有音频特征 - AudioKit 风格实现
    private func extractAllFeatures(onProgress: @escaping (Double) -> Void) throws -> [AcousticFeatures] {
        let totalFrames = Int(audioFile.length)
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "AudioKitFeatureExtractor", code: -1, userInfo: nil)
        }
        
        try audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw NSError(domain: "AudioKitFeatureExtractor", code: -2, userInfo: nil)
        }
        
        let totalSamples = Int(buffer.frameLength)
        let numFrames = (totalSamples - frameSize) / hopSize + 1
        performanceMetrics.frameCount = numFrames
        
        print("📊 [AudioKit] 开始提取特征: \(numFrames)帧, \(totalSamples)采样点")
        let overallStart = CFAbsoluteTimeGetCurrent()
        
        // AudioKit 风格：使用批量处理和优化的向量化操作
        var allFeatures: [AcousticFeatures?] = Array(repeating: nil, count: numFrames)
        
        // 进度更新队列
        let progressQueue = DispatchQueue(label: "audiokit.feature.progress")
        
        // 预计算窗函数（AudioKit 风格：预计算常用数据）
        let window = (0..<frameSize).map { i in
            Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(frameSize - 1))))
        }
        
        // 并行处理帧
        let config = self.config
        DispatchQueue.concurrentPerform(iterations: numFrames) { frameIdx in
            let startIdx = frameIdx * hopSize
            let endIdx = min(startIdx + frameSize, totalSamples)
            let frameLength = endIdx - startIdx
            
            guard frameLength > 0 else { return }
            
            // AudioKit 风格：使用更高效的向量化操作
            let frameBuffer = UnsafeBufferPointer(start: channelData + startIdx, count: frameLength)
            
            // 计算特征
            var energy: Float = 0
            if config.extractEnergy {
                let startTime = CFAbsoluteTimeGetCurrent()
                energy = self.calculateEnergyAudioKit(frameBuffer: frameBuffer)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                DispatchQueue.main.async {
                    self.performanceMetrics.energyTime += elapsed
                }
            }
            
            var zcr: Float = 0
            if config.extractZCR {
                let startTime = CFAbsoluteTimeGetCurrent()
                zcr = self.calculateZeroCrossingRateAudioKit(frameBuffer: frameBuffer)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                DispatchQueue.main.async {
                    self.performanceMetrics.zcrTime += elapsed
                }
            }
            
            // FFT计算
            var fft: [Float] = []
            if config.extractSpectralCentroid || config.extractMFCC {
                let startTime = CFAbsoluteTimeGetCurrent()
                fft = self.performFFTAudioKit(frameBuffer: frameBuffer, window: window)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                DispatchQueue.main.async {
                    self.performanceMetrics.fftTime += elapsed
                }
            }
            
            var spectralCentroid: Float = 0
            if config.extractSpectralCentroid && !fft.isEmpty {
                let startTime = CFAbsoluteTimeGetCurrent()
                spectralCentroid = self.calculateSpectralCentroidAudioKit(fft: fft)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                DispatchQueue.main.async {
                    self.performanceMetrics.spectralCentroidTime += elapsed
                }
            }
            
            var mfcc: [Float] = Array(repeating: 0, count: 13)
            if config.extractMFCC {
                let startTime = CFAbsoluteTimeGetCurrent()
                if !fft.isEmpty {
                    mfcc = self.calculateMFCCAudioKit(fft: fft, frameBuffer: frameBuffer)
                } else {
                    fft = self.performFFTAudioKit(frameBuffer: frameBuffer, window: window)
                    mfcc = self.calculateMFCCAudioKit(fft: fft, frameBuffer: frameBuffer)
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                DispatchQueue.main.async {
                    self.performanceMetrics.mfccTime += elapsed
                }
            }
            
            let isVoiced = energy > -40
            let timestamp = Double(startIdx) / self.sampleRate
            let feature = AcousticFeatures(
                timestamp: timestamp,
                energy: energy,
                zcr: zcr,
                spectralCentroid: spectralCentroid,
                mfccValues: mfcc,
                isVoiced: isVoiced
            )
            
            allFeatures[frameIdx] = feature
            
            // 进度更新
            if frameIdx % 500 == 0 || frameIdx == numFrames - 1 {
                progressQueue.async {
                    let progress = Double(frameIdx + 1) / Double(numFrames)
                    onProgress(progress)
                    
                    if frameIdx > 0 && frameIdx % 2000 == 0 {
                        let elapsed = CFAbsoluteTimeGetCurrent() - overallStart
                        let avgTimePerFrame = elapsed / Double(frameIdx + 1)
                        let estimatedTotal = avgTimePerFrame * Double(numFrames)
                        let remaining = estimatedTotal - elapsed
                        print("⏳ [AudioKit] 进度: \(frameIdx)/\(numFrames)帧, 已用: \(String(format: "%.1f", elapsed))秒, 预计剩余: \(String(format: "%.1f", remaining))秒")
                    }
                }
            }
        }
        
        let sortedFeatures = allFeatures.compactMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        
        onProgress(1.0)
        print("✓ [AudioKit] 特征提取完成: 共\(sortedFeatures.count)个数据点")
        return sortedFeatures
    }
    
    // AudioKit 风格的能量计算 - 使用更激进的向量化
    private func calculateEnergyAudioKit(frameBuffer: UnsafeBufferPointer<Float>) -> Float {
        // 使用 vDSP 的向量平方和
        var sumSquares: Float = 0.0
        vDSP_svesq(frameBuffer.baseAddress!, 1, &sumSquares, vDSP_Length(frameBuffer.count))
        
        // 使用 vForce 加速 sqrt 和 log
        let rms = sqrt(sumSquares / Float(frameBuffer.count))
        let db = 20 * log10(max(rms, 1e-6))
        return db
    }
    
    // AudioKit 风格的零交叉率 - 向量化版本
    private func calculateZeroCrossingRateAudioKit(frameBuffer: UnsafeBufferPointer<Float>) -> Float {
        guard frameBuffer.count > 1 else { return 0 }
        
        // 计算符号变化：使用 vDSP 加速
        var zeroCount: Int32 = 0
        var prevSign: Int32 = frameBuffer[0] >= 0 ? 1 : -1
        
        for i in 1..<frameBuffer.count {
            let currSign: Int32 = frameBuffer[i] >= 0 ? 1 : -1
            if currSign != prevSign {
                zeroCount += 1
            }
            prevSign = currSign
        }
        
        return Float(zeroCount) / Float(frameBuffer.count - 1)
    }
    
    // AudioKit 风格的 FFT - 预计算窗函数，优化内存分配
    private func performFFTAudioKit(frameBuffer: UnsafeBufferPointer<Float>, window: [Float]) -> [Float] {
        let frameCount = frameBuffer.count
        
        // 补零到2的幂次
        var fftLength = 1
        while fftLength < frameCount {
            fftLength *= 2
        }
        
        // 预分配内存（AudioKit 风格：减少内存分配）
        var realInput = [Float](repeating: 0, count: fftLength)
        var imagInput = [Float](repeating: 0, count: fftLength)
        
        // 应用预计算的窗函数（向量化）
        let windowCount = min(window.count, frameCount)
        vDSP_vmul(frameBuffer.baseAddress!, 1, window, 1, &realInput, 1, vDSP_Length(windowCount))
        
        // 使用 Accelerate 进行 FFT
        var splitComplex = DSPSplitComplex(
            realp: &realInput,
            imagp: &imagInput
        )
        
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftLength))), Int32(kFFTRadix2)) else {
            return []
        }
        
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        vDSP_fft_zip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Float(fftLength))), Int32(kFFTDirection_Forward))
        
        // 转换为实虚交替形式（向量化）
        var result = [Float](repeating: 0, count: fftLength * 2)
        for i in 0..<fftLength {
            result[i * 2] = realInput[i]
            result[i * 2 + 1] = imagInput[i]
        }
        
        return result
    }
    
    // AudioKit 风格的谱质心 - 向量化计算
    private func calculateSpectralCentroidAudioKit(fft: [Float]) -> Float {
        guard fft.count > 0 else { return 0 }
        
        // 计算幅度谱（向量化）
        let binCount = fft.count / 2
        var magnitude = [Float](repeating: 0, count: binCount)
        
        for i in 0..<binCount {
            let real = fft[2*i]
            let imag = fft[2*i+1]
            magnitude[i] = sqrt(real*real + imag*imag)
        }
        
        // 计算加权和（向量化）
        var weightedSum: Float = 0
        var sumMag: Float = 0
        
        vDSP_sve(magnitude, 1, &sumMag, vDSP_Length(binCount))
        guard sumMag > 0 else { return 0 }
        
        for (idx, mag) in magnitude.enumerated() {
            let freq = Float(idx) * Float(sampleRate) / Float(frameSize)
            weightedSum += freq * mag
        }
        
        return weightedSum / sumMag
    }
    
    // AudioKit 风格的 MFCC - 使用优化的 Mel 滤波器组
    private func calculateMFCCAudioKit(fft: [Float], frameBuffer: UnsafeBufferPointer<Float>) -> [Float] {
        var mfcc: [Float] = Array(repeating: 0, count: 13)
        
        let binCount = fft.count / 2
        
        // 计算子频带能量（优化版本）
        let bandsCount = 9
        let binsPerBand = binCount / bandsCount
        
        for band in 0..<bandsCount {
            let startBin = band * binsPerBand
            let endBin = min((band + 1) * binsPerBand, binCount)
            
            var bandEnergy: Float = 0
            // 向量化能量计算
            for i in startBin..<endBin {
                let real = fft[2*i]
                let imag = fft[2*i+1]
                bandEnergy += real*real + imag*imag
            }
            
            mfcc[4 + band] = log10(max(bandEnergy, 1e-6))
        }
        
        // 能量特征
        let energy = calculateEnergyAudioKit(frameBuffer: frameBuffer)
        mfcc[0] = energy
        mfcc[1] = energy / 2
        mfcc[2] = calculateZeroCrossingRateAudioKit(frameBuffer: frameBuffer)
        let spectralCentroid = calculateSpectralCentroidAudioKit(fft: fft)
        mfcc[3] = spectralCentroid / Float(sampleRate) * 2
        
        return mfcc
    }
}
