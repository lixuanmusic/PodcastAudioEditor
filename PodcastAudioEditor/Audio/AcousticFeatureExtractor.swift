import AVFoundation
import Accelerate

// 特征提取配置
struct FeatureExtractionConfig {
    var extractEnergy: Bool = true       // 能量（必须，用于静音和响度检测）
    var extractZCR: Bool = false         // 零交叉率（可选，辅助分类）
    var extractSpectralCentroid: Bool = false  // 谱质心（可选，辅助分类）
    var extractMFCC: Bool = true         // MFCC（建议，用于分类和发言人识别）
    
    // 极速模式：只提取能量（静音+响度检测，无FFT）
    static let ultraFast = FeatureExtractionConfig(
        extractEnergy: true,
        extractZCR: false,
        extractSpectralCentroid: false,
        extractMFCC: false
    )
    
    // 快速模式：能量+MFCC（支持分类和发言人识别）
    static let fast = FeatureExtractionConfig(
        extractEnergy: true,
        extractZCR: false,
        extractSpectralCentroid: false,
        extractMFCC: true
    )
    
    // 完整模式：提取所有特征
    static let full = FeatureExtractionConfig(
        extractEnergy: true,
        extractZCR: true,
        extractSpectralCentroid: true,
        extractMFCC: true
    )
}

// 性能统计结构
struct PerformanceMetrics {
    var energyTime: TimeInterval = 0
    var zcrTime: TimeInterval = 0
    var spectralCentroidTime: TimeInterval = 0
    var fftTime: TimeInterval = 0
    var mfccTime: TimeInterval = 0
    var frameCount: Int = 0
    
    var totalTime: TimeInterval {
        energyTime + zcrTime + spectralCentroidTime + fftTime + mfccTime
    }
    
    var report: String {
        """
        ⏱️  性能分析报告
        ===================
        总帧数: \(frameCount)
        总耗时: \(String(format: "%.3f", totalTime))秒
        
        各特征耗时:
        - 能量计算: \(String(format: "%.3f", energyTime))秒 (\(String(format: "%.1f", energyTime/totalTime*100))%)
        - 零交叉率: \(String(format: "%.3f", zcrTime))秒 (\(String(format: "%.1f", zcrTime/totalTime*100))%)
        - 谱质心: \(String(format: "%.3f", spectralCentroidTime))秒 (\(String(format: "%.1f", spectralCentroidTime/totalTime*100))%)
        - FFT计算: \(String(format: "%.3f", fftTime))秒 (\(String(format: "%.1f", fftTime/totalTime*100))%)
        - MFCC: \(String(format: "%.3f", mfccTime))秒 (\(String(format: "%.1f", mfccTime/totalTime*100))%)
        
        平均每帧耗时: \(String(format: "%.4f", totalTime/Double(frameCount)))秒 (约\(String(format: "%.2f", totalTime/Double(frameCount) * 1000))毫秒)
        ===================
        """
    }
}

// 声学特征数据结构
struct AcousticFeatures {
    let timestamp: Double  // 时间戳（秒）
    let energy: Float      // 能量（dB）
    let zcr: Float         // 零交叉率（0-1）
    let spectralCentroid: Float  // 谱质心（Hz）
    let mfccValues: [Float]      // MFCC系数（13维）
    let isVoiced: Bool     // 是否有声段
    
    var description: String {
        "时间: \(String(format: "%.2f", timestamp))s, 能量: \(String(format: "%.1f", energy))dB, ZCR: \(String(format: "%.3f", zcr)), 质心: \(String(format: "%.0f", spectralCentroid))Hz, 有声: \(isVoiced)"
    }
}

final class AcousticFeatureExtractor {
    private let audioFile: AVAudioFile
    private let sampleRate: Double
    private let frameSize: Int = 1024  // 分帧大小（约23ms @ 44100Hz，满足语音分析需求）
    private let hopSize: Int = 768     // 帧移（25%重叠，平衡性能和时间分辨率）
    private let config: FeatureExtractionConfig  // 特征提取配置
    
    var features: [AcousticFeatures] = []
    var isProcessing: Bool = false
    var performanceMetrics = PerformanceMetrics()  // 性能统计
    
    init?(audioFileURL: URL, config: FeatureExtractionConfig = .fast) {
        guard let audioFile = try? AVAudioFile(forReading: audioFileURL) else {
            return nil
        }
        self.audioFile = audioFile
        self.sampleRate = audioFile.processingFormat.sampleRate
        self.config = config
        print("📋 特征提取配置: 能量=\(config.extractEnergy), ZCR=\(config.extractZCR), 谱质心=\(config.extractSpectralCentroid), MFCC=\(config.extractMFCC)")
    }
    
    // 异步提取所有特征
    func extractFeaturesAsync(onProgress: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        isProcessing = true
        performanceMetrics = PerformanceMetrics()  // 重置统计
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                DispatchQueue.main.async {
                    self?.isProcessing = false
                    // 输出性能报告
                    if let metrics = self?.performanceMetrics {
                        print(metrics.report)
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
                print("⏱️  总分析耗时: \(String(format: "%.3f", overallTime))秒")
                
                DispatchQueue.main.async {
                    self.features = features
                }
            } catch {
                print("❌ 特征提取失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 提取所有音频特征
    private func extractAllFeatures(onProgress: @escaping (Double) -> Void) throws -> [AcousticFeatures] {
        let totalFrames = Int(audioFile.length)
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "FeatureExtractor", code: -1, userInfo: nil)
        }
        
        try audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw NSError(domain: "FeatureExtractor", code: -2, userInfo: nil)
        }
        
        let totalSamples = Int(buffer.frameLength)
        let numFrames = (totalSamples - frameSize) / hopSize + 1
        performanceMetrics.frameCount = numFrames
        
        print("📊 开始提取特征: \(numFrames)帧, \(totalSamples)采样点")
        let overallStart = CFAbsoluteTimeGetCurrent()
        
        // 并行处理：使用线程安全的结果数组和性能统计
        let resultsQueue = DispatchQueue(label: "feature.results")
        let metricsQueue = DispatchQueue(label: "feature.metrics")
        
        var allFeatures: [AcousticFeatures?] = Array(repeating: nil, count: numFrames)
        
        // 并行处理帧
        let config = self.config  // 捕获配置避免重复访问
        DispatchQueue.concurrentPerform(iterations: numFrames) { frameIdx in
            let startIdx = frameIdx * hopSize
            let endIdx = min(startIdx + frameSize, totalSamples)
            let frameLength = endIdx - startIdx
            
            guard frameLength > 0 else { return }
            
            // 直接使用指针，避免数组拷贝
            let frameBuffer = UnsafeBufferPointer(start: channelData + startIdx, count: frameLength)
            
            // 计算特征（根据配置选择性计算，带计时）
            var energy: Float = 0
            var energyTime: TimeInterval = 0
            if config.extractEnergy {
                let start = CFAbsoluteTimeGetCurrent()
                energy = self.calculateEnergyFast(frameBuffer: frameBuffer)
                energyTime = CFAbsoluteTimeGetCurrent() - start
            }
                
            var zcr: Float = 0
            var zcrTime: TimeInterval = 0
            if config.extractZCR {
                let start = CFAbsoluteTimeGetCurrent()
                zcr = self.calculateZeroCrossingRateFast(frameBuffer: frameBuffer)
                zcrTime = CFAbsoluteTimeGetCurrent() - start
            }
            
            // FFT只在需要谱质心或MFCC时计算
            var fft: [Float] = []
            var fftTime: TimeInterval = 0
            if config.extractSpectralCentroid || config.extractMFCC {
                let start = CFAbsoluteTimeGetCurrent()
                fft = self.performFFT(frameBuffer: frameBuffer)
                fftTime = CFAbsoluteTimeGetCurrent() - start
            }
            
            var spectralCentroid: Float = 0
            var centroidTime: TimeInterval = 0
            if config.extractSpectralCentroid && !fft.isEmpty {
                let start = CFAbsoluteTimeGetCurrent()
                spectralCentroid = self.calculateSpectralCentroidFromFFT(fft: fft)
                centroidTime = CFAbsoluteTimeGetCurrent() - start
            }
            
            var mfcc: [Float] = Array(repeating: 0, count: 13)
            var mfccTime: TimeInterval = 0
            if config.extractMFCC {
                let start = CFAbsoluteTimeGetCurrent()
                if !fft.isEmpty {
                    mfcc = self.calculateMFCCFromFFT(fft: fft, frameBuffer: frameBuffer)
                } else {
                    // 如果之前没计算FFT，现在计算
                    let fftStart = CFAbsoluteTimeGetCurrent()
                    fft = self.performFFT(frameBuffer: frameBuffer)
                    fftTime += CFAbsoluteTimeGetCurrent() - fftStart
                    mfcc = self.calculateMFCCFromFFT(fft: fft, frameBuffer: frameBuffer)
                }
                mfccTime = CFAbsoluteTimeGetCurrent() - start
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
            
            // 线程安全地更新结果
            resultsQueue.async {
                allFeatures[frameIdx] = feature
                let currentCount = allFeatures.compactMap { $0 }.count  // 线程安全计数
                
                // 更新进度（只在特定帧数时更新，减少竞争）
                if frameIdx % 100 == 0 || frameIdx == numFrames - 1 {
                    let progress = Double(currentCount) / Double(numFrames)
                    onProgress(progress)
                }
                
                // 每1000帧输出进度
                if frameIdx > 0 && frameIdx % 1000 == 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - overallStart
                    let avgTimePerFrame = elapsed / Double(frameIdx + 1)
                    let estimatedTotal = avgTimePerFrame * Double(numFrames)
                    let remaining = estimatedTotal - elapsed
                    print("⏳ 进度: \(frameIdx)/\(numFrames)帧, 已用: \(String(format: "%.1f", elapsed))秒, 预计剩余: \(String(format: "%.1f", remaining))秒")
                }
            }
            
            // 累加性能统计（线程安全）
            metricsQueue.async {
                self.performanceMetrics.energyTime += energyTime
                self.performanceMetrics.zcrTime += zcrTime
                self.performanceMetrics.fftTime += fftTime
                self.performanceMetrics.spectralCentroidTime += centroidTime
                self.performanceMetrics.mfccTime += mfccTime
            }
        }
        
        // 等待所有帧处理完成
        resultsQueue.sync {}
        metricsQueue.sync {}
        
        // 过滤nil并排序（确保时间顺序）
        let sortedFeatures = allFeatures.compactMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        
        onProgress(1.0)
        print("✓ 特征提取完成: 共\(sortedFeatures.count)个数据点")
        return sortedFeatures
    }
    
    // 计算能量（dB）- 使用UnsafeBufferPointer避免拷贝
    private func calculateEnergyFast(frameBuffer: UnsafeBufferPointer<Float>) -> Float {
        var sumSquares: Float = 0.0
        vDSP_svesq(frameBuffer.baseAddress!, 1, &sumSquares, vDSP_Length(frameBuffer.count))
        let rms = sqrt(sumSquares / Float(frameBuffer.count))
        let db = 20 * log10(max(rms, 1e-6))
        return db
    }
    
    // 计算能量（dB）- 兼容方法
    private func calculateEnergy(frame: [Float]) -> Float {
        let sumSquares = frame.reduce(0.0) { $0 + $1 * $1 }
        let rms = sqrt(sumSquares / Float(frame.count))
        let db = 20 * log10(max(rms, 1e-6))
        return db
    }
    
    // 计算零交叉率（0-1）- 使用UnsafeBufferPointer
    private func calculateZeroCrossingRateFast(frameBuffer: UnsafeBufferPointer<Float>) -> Float {
        guard frameBuffer.count > 1 else { return 0 }
        var zeroCount = 0
        for i in 1..<frameBuffer.count {
            let curr = frameBuffer[i]
            let prev = frameBuffer[i-1]
            if (curr >= 0 && prev < 0) || (curr < 0 && prev >= 0) {
                zeroCount += 1
            }
        }
        return Float(zeroCount) / Float(frameBuffer.count - 1)
    }
    
    // 计算零交叉率（0-1）- 兼容方法
    private func calculateZeroCrossingRate(frame: [Float]) -> Float {
        guard frame.count > 1 else { return 0 }
        var zeroCount = 0
        for i in 1..<frame.count {
            if (frame[i] >= 0 && frame[i-1] < 0) || (frame[i] < 0 && frame[i-1] >= 0) {
                zeroCount += 1
            }
        }
        return Float(zeroCount) / Float(frame.count - 1)
    }
    
    // 计算谱质心（Hz）- 使用已计算的FFT结果
    private func calculateSpectralCentroidFromFFT(fft: [Float]) -> Float {
        guard fft.count > 0 else { return 0 }
        
        // 计算幅度谱
        var magnitude: [Float] = []
        for i in 0..<fft.count/2 {
            let real = fft[2*i]
            let imag = fft[2*i+1]
            let mag = sqrt(real*real + imag*imag)
            magnitude.append(mag)
        }
        
        // 计算谱质心
        let sumMag = magnitude.reduce(0, +)
        guard sumMag > 0 else { return 0 }
        
        var centroid: Float = 0
        for (idx, mag) in magnitude.enumerated() {
            let freq = Float(idx) * Float(sampleRate) / Float(frameSize)
            centroid += freq * mag
        }
        
        return centroid / sumMag
    }
    
    // 计算MFCC（梅尔频率倒谱系数，13维）- 使用已计算的FFT结果和UnsafeBufferPointer
    private func calculateMFCCFromFFT(fft: [Float], frameBuffer: UnsafeBufferPointer<Float>) -> [Float] {
        // 简化版MFCC：使用对数能量+频率特性
        // 完整实现需要Mel滤波组和离散余弦变换
        
        // 这里使用简化的13维特征：
        // - 前4维：帧能量的时间导数
        // - 后9维：均匀分布的子频带能量
        
        var mfcc: [Float] = Array(repeating: 0, count: 13)
        
        let binCount = fft.count / 2
        
        // 计算子频带能量
        let bandsCount = 9
        let binsPerBand = binCount / bandsCount
        
        for band in 0..<bandsCount {
            let startBin = band * binsPerBand
            let endBin = min((band + 1) * binsPerBand, binCount)
            
            var bandEnergy: Float = 0
            for i in startBin..<endBin {
                let real = fft[2*i]
                let imag = fft[2*i+1]
                bandEnergy += real*real + imag*imag
            }
            
            mfcc[4 + band] = log10(max(bandEnergy, 1e-6))
        }
        
        // 能量特征（使用快速方法）
        let energy = calculateEnergyFast(frameBuffer: frameBuffer)
        mfcc[0] = energy
        mfcc[1] = energy / 2  // 简化导数近似
        mfcc[2] = calculateZeroCrossingRateFast(frameBuffer: frameBuffer)
        let spectralCentroid = calculateSpectralCentroidFromFFT(fft: fft)
        mfcc[3] = spectralCentroid / Float(sampleRate) * 2  // 归一化
        
        return mfcc
    }
    
    // 兼容方法
    private func calculateMFCCFromFFT(fft: [Float], frame: [Float]) -> [Float] {
        let frameBuffer = UnsafeBufferPointer(start: frame, count: frame.count)
        return calculateMFCCFromFFT(fft: fft, frameBuffer: frameBuffer)
    }
    
    // 执行FFT - 使用UnsafeBufferPointer避免拷贝
    private func performFFT(frameBuffer: UnsafeBufferPointer<Float>) -> [Float] {
        let frameCount = frameBuffer.count
        
        // 补零到2的幂次
        var fftLength = 1
        while fftLength < frameCount {
            fftLength *= 2
        }
        
        // 分配内存（应用Hann窗并补零）
        var realInput = [Float](repeating: 0, count: fftLength)
        var imagInput = [Float](repeating: 0, count: fftLength)
        
        // 应用Hann窗并复制数据
        for i in 0..<frameCount {
            let window = Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(frameCount - 1))))
            realInput[i] = frameBuffer[i] * window
        }
        
        // 使用Accelerate进行FFT
        var splitComplex = DSPSplitComplex(
            realp: &realInput,
            imagp: &imagInput
        )
        
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftLength))), Int32(kFFTRadix2)) else {
            return []
        }
        
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        vDSP_fft_zip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Float(fftLength))), Int32(kFFTDirection_Forward))
        
        // 将结果转换为实虚交替的形式
        var result: [Float] = []
        result.reserveCapacity(fftLength * 2)
        for i in 0..<fftLength {
            result.append(realInput[i])
            result.append(imagInput[i])
        }
        
        return result
    }
    
    // 兼容方法
    private func performFFT(frame: [Float]) -> [Float] {
        let frameBuffer = UnsafeBufferPointer(start: frame, count: frame.count)
        return performFFT(frameBuffer: frameBuffer)
    }
}
