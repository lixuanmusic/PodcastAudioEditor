import AVFoundation
import Accelerate

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
    
    var features: [AcousticFeatures] = []
    var isProcessing: Bool = false
    var performanceMetrics = PerformanceMetrics()  // 性能统计
    
    init?(audioFileURL: URL) {
        guard let audioFile = try? AVAudioFile(forReading: audioFileURL) else {
            return nil
        }
        self.audioFile = audioFile
        self.sampleRate = audioFile.processingFormat.sampleRate
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
        
        var allFeatures: [AcousticFeatures] = []
        let totalSamples = Int(buffer.frameLength)
        let numFrames = (totalSamples - frameSize) / hopSize + 1
        performanceMetrics.frameCount = numFrames
        
        print("📊 开始提取特征: \(numFrames)帧, \(totalSamples)采样点")
        let overallStart = CFAbsoluteTimeGetCurrent()
        
        for frameIdx in 0..<numFrames {
            let startIdx = frameIdx * hopSize
            let endIdx = min(startIdx + frameSize, totalSamples)
            let frameLength = endIdx - startIdx
            
            guard frameLength > 0 else { continue }
            
            // 提取当前帧
            let frame = Array(UnsafeBufferPointer(start: channelData + startIdx, count: frameLength))
            
            // 计算特征（带计时）
            let energyStart = CFAbsoluteTimeGetCurrent()
            let energy = calculateEnergy(frame: frame)
            performanceMetrics.energyTime += CFAbsoluteTimeGetCurrent() - energyStart
            
            let zcrStart = CFAbsoluteTimeGetCurrent()
            let zcr = calculateZeroCrossingRate(frame: frame)
            performanceMetrics.zcrTime += CFAbsoluteTimeGetCurrent() - zcrStart
            
            // 先计算FFT（一次，用于多个特征）
            let fftStart = CFAbsoluteTimeGetCurrent()
            let fft = performFFT(frame: frame)
            performanceMetrics.fftTime += CFAbsoluteTimeGetCurrent() - fftStart
            
            let centroidStart = CFAbsoluteTimeGetCurrent()
            let spectralCentroid = calculateSpectralCentroidFromFFT(fft: fft)
            performanceMetrics.spectralCentroidTime += CFAbsoluteTimeGetCurrent() - centroidStart
            
            let mfccStart = CFAbsoluteTimeGetCurrent()
            let mfcc = calculateMFCCFromFFT(fft: fft, frame: frame)
            performanceMetrics.mfccTime += CFAbsoluteTimeGetCurrent() - mfccStart
            
            let isVoiced = energy > -40  // 简单判断：能量 > -40dB 认为有声
            
            let timestamp = Double(startIdx) / sampleRate
            let feature = AcousticFeatures(
                timestamp: timestamp,
                energy: energy,
                zcr: zcr,
                spectralCentroid: spectralCentroid,
                mfccValues: mfcc,
                isVoiced: isVoiced
            )
            
            allFeatures.append(feature)
            
            // 进度回调
            if frameIdx % 100 == 0 || frameIdx == numFrames - 1 {
                let progress = Double(frameIdx + 1) / Double(numFrames)
                onProgress(progress)
                
                // 每1000帧输出一次中间进度
                if frameIdx % 1000 == 0 && frameIdx > 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - overallStart
                    let avgTimePerFrame = elapsed / Double(frameIdx + 1)
                    let estimatedTotal = avgTimePerFrame * Double(numFrames)
                    let remaining = estimatedTotal - elapsed
                    print("⏳ 进度: \(frameIdx)/\(numFrames)帧, 已用: \(String(format: "%.1f", elapsed))秒, 预计剩余: \(String(format: "%.1f", remaining))秒")
                }
            }
        }
        
        onProgress(1.0)
        print("✓ 特征提取完成: 共\(allFeatures.count)个数据点")
        return allFeatures
    }
    
    // 计算能量（dB）
    private func calculateEnergy(frame: [Float]) -> Float {
        let sumSquares = frame.reduce(0.0) { $0 + $1 * $1 }
        let rms = sqrt(sumSquares / Float(frame.count))
        // 转换为dB（以1.0为参考）
        let db = 20 * log10(max(rms, 1e-6))
        return db
    }
    
    // 计算零交叉率（0-1）
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
    
    // 计算MFCC（梅尔频率倒谱系数，13维）- 使用已计算的FFT结果
    private func calculateMFCCFromFFT(fft: [Float], frame: [Float]) -> [Float] {
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
        
        // 能量特征
        let energy = calculateEnergy(frame: frame)
        mfcc[0] = energy
        mfcc[1] = energy / 2  // 简化导数近似
        mfcc[2] = calculateZeroCrossingRate(frame: frame)
        let spectralCentroid = calculateSpectralCentroidFromFFT(fft: fft)
        mfcc[3] = spectralCentroid / Float(sampleRate) * 2  // 归一化
        
        return mfcc
    }
    
    // 执行FFT
    private func performFFT(frame: [Float]) -> [Float] {
        var input = frame
        
        // 应用Hann窗
        for i in 0..<input.count {
            let window = Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(input.count - 1))))
            input[i] *= window
        }
        
        // 补零到2的幂次
        var fftLength = 1
        while fftLength < input.count {
            fftLength *= 2
        }
        
        var realInput = Array(input) + Array(repeating: Float(0), count: fftLength - input.count)
        var imagInput = Array(repeating: Float(0), count: fftLength)
        
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
        for i in 0..<fftLength {
            result.append(realInput[i])
            result.append(imagInput[i])
        }
        
        return result
    }
}
