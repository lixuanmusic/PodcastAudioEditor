import SwiftUI
import Combine

class AudioAnalysisViewModel: ObservableObject {
    @Published var features: [AcousticFeatures] = []
    @Published var segments: [Segment] = []
    @Published var isAnalyzing = false
    @Published var analysisProgress: Double = 0.0
    @Published var showAnalysisWindow = false
    
    // 提取器选择和性能对比
    @Published var selectedExtractor: FeatureExtractorType = .accelerate
    @Published var comparePerformance: Bool = false
    @Published var accelerateMetrics: PerformanceMetrics?
    @Published var audioKitMetrics: PerformanceMetrics?
    @Published var performanceComparison: String = ""
    
    private var featureExtractor: FeatureExtractorProtocol?
    private var segmentDetector: SegmentDetector?
    
    // 性能对比时临时保存提取器
    private var accelerateExtractorForComparison: AccelerateFeatureExtractor?
    private var audioKitExtractorForComparison: AudioKitFeatureExtractor?
    
    // 统计信息
    @Published var totalSilenceDuration: Double = 0.0
    @Published var totalSpeechDuration: Double = 0.0
    @Published var totalMusicDuration: Double = 0.0
    @Published var averageEnergy: Float = 0.0
    @Published var averageZCR: Float = 0.0
    
    // 分析音频文件
    func analyzeAudioFile(url: URL) {
        if comparePerformance {
            // 性能对比模式：两种方案都运行
            performComparison(url: url)
        } else {
            // 单方案模式
            analyzeWithExtractor(url: url, type: selectedExtractor)
        }
    }
    
    // 使用指定提取器分析
    private func analyzeWithExtractor(url: URL, type: FeatureExtractorType) {
        let extractor: FeatureExtractorProtocol?
        
        switch type {
        case .accelerate:
            extractor = AccelerateFeatureExtractor(audioFileURL: url)
        case .audioKit:
            extractor = AudioKitFeatureExtractor(audioFileURL: url)
        }
        
        guard let extractor = extractor else {
            print("❌ 无法创建特征提取器: \(type.description)")
            return
        }
        
        self.featureExtractor = extractor
        isAnalyzing = true
        analysisProgress = 0.0
        
        extractor.extractFeaturesAsync(
            onProgress: { [weak self] progress in
                self?.analysisProgress = progress * 0.7  // 前70%用于特征提取
            },
            completion: { [weak self] in
                self?.onFeaturesExtracted(features: extractor.features, metrics: extractor.performanceMetrics)
            }
        )
    }
    
    // 性能对比模式
    private func performComparison(url: URL) {
        isAnalyzing = true
        analysisProgress = 0.0
        accelerateMetrics = nil
        audioKitMetrics = nil
        
        print("📊 开始性能对比测试")
        print(String(repeating: "=", count: 50))
        
        // 先运行 Accelerate
        print("\n🔵 测试 Accelerate 方案...")
        guard let accelerateExtractor = AccelerateFeatureExtractor(audioFileURL: url) else {
            print("❌ 无法创建 Accelerate 提取器")
            return
        }
        
        self.accelerateExtractorForComparison = accelerateExtractor
        let accelerateStart = CFAbsoluteTimeGetCurrent()
        accelerateExtractor.extractFeaturesAsync(
            onProgress: { [weak self] progress in
                DispatchQueue.main.async {
                    // 前50%进度用于 Accelerate
                    self?.analysisProgress = progress * 0.5
                }
            },
            completion: { [weak self] in
                let accelerateTime = CFAbsoluteTimeGetCurrent() - accelerateStart
                DispatchQueue.main.async {
                    self?.accelerateMetrics = accelerateExtractor.performanceMetrics
                    print("✅ Accelerate 完成，耗时: \(String(format: "%.3f", accelerateTime))秒")
                    
                    // 然后运行 AudioKit
                    self?.runAudioKitExtractor(url: url, accelerateTime: accelerateTime)
                }
            }
        )
    }
    
    // 运行 AudioKit 提取器（在性能对比模式中）
    private func runAudioKitExtractor(url: URL, accelerateTime: TimeInterval) {
        print("\n🟢 测试 AudioKit 方案...")
        guard let audioKitExtractor = AudioKitFeatureExtractor(audioFileURL: url) else {
            print("❌ 无法创建 AudioKit 提取器")
            return
        }
        
        self.audioKitExtractorForComparison = audioKitExtractor
        let audioKitStart = CFAbsoluteTimeGetCurrent()
        audioKitExtractor.extractFeaturesAsync(
            onProgress: { [weak self] progress in
                DispatchQueue.main.async {
                    // 后50%进度用于 AudioKit (0.5 + progress * 0.5)
                    self?.analysisProgress = 0.5 + progress * 0.5
                }
            },
            completion: { [weak self] in
                let audioKitTime = CFAbsoluteTimeGetCurrent() - audioKitStart
                DispatchQueue.main.async {
                    self?.audioKitMetrics = audioKitExtractor.performanceMetrics
                    print("✅ AudioKit 完成，耗时: \(String(format: "%.3f", audioKitTime))秒")
                    
                    // 生成对比报告
                    self?.generateComparisonReport(accelerateTime: accelerateTime, audioKitTime: audioKitTime)
                    
                    // 使用选中的提取器的结果
                    guard let accelerateExtractor = self?.accelerateExtractorForComparison else { return }
                    let finalExtractor: FeatureExtractorProtocol = self?.selectedExtractor == .accelerate ? accelerateExtractor : audioKitExtractor
                    self?.featureExtractor = finalExtractor
                    self?.onFeaturesExtracted(features: finalExtractor.features, metrics: finalExtractor.performanceMetrics)
                }
            }
        )
    }
    
    // 生成性能对比报告
    private func generateComparisonReport(accelerateTime: TimeInterval, audioKitTime: TimeInterval) {
        guard let accMetrics = accelerateMetrics,
              let akMetrics = audioKitMetrics else { return }
        
        let faster = accelerateTime < audioKitTime ? "Accelerate" : "AudioKit"
        let speedup = max(accelerateTime, audioKitTime) / min(accelerateTime, audioKitTime)
        let percentDiff = abs(accelerateTime - audioKitTime) / min(accelerateTime, audioKitTime) * 100
        
        var report = """
        📊 性能对比报告
        ========================================
        
        总耗时对比:
        - Accelerate: \(String(format: "%.3f", accelerateTime))秒
        - AudioKit:   \(String(format: "%.3f", audioKitTime))秒
        - 更快方案:   \(faster)
        - 加速比:     \(String(format: "%.2f", speedup))x
        - 性能差异:   \(String(format: "%.1f", percentDiff))%
        
        """
        
        // 详细特征对比
        report += "\n各特征耗时对比:\n"
        report += String(format: "%-20s %12s %12s %10s\n", "特征", "Accelerate", "AudioKit", "差异")
        report += String(repeating: "-", count: 56) + "\n"
        
        if accMetrics.energyTime > 0 || akMetrics.energyTime > 0 {
            let diff = abs(accMetrics.energyTime - akMetrics.energyTime) / min(accMetrics.energyTime, akMetrics.energyTime) * 100
            report += String(format: "%-20s %10.3fs %10.3fs %9.1f%%\n", "能量", accMetrics.energyTime, akMetrics.energyTime, diff)
        }
        
        if accMetrics.zcrTime > 0 || akMetrics.zcrTime > 0 {
            let diff = abs(accMetrics.zcrTime - akMetrics.zcrTime) / max(min(accMetrics.zcrTime, akMetrics.zcrTime), 0.001) * 100
            report += String(format: "%-20s %10.3fs %10.3fs %9.1f%%\n", "零交叉率", accMetrics.zcrTime, akMetrics.zcrTime, diff)
        }
        
        if accMetrics.spectralCentroidTime > 0 || akMetrics.spectralCentroidTime > 0 {
            let diff = abs(accMetrics.spectralCentroidTime - akMetrics.spectralCentroidTime) / max(min(accMetrics.spectralCentroidTime, akMetrics.spectralCentroidTime), 0.001) * 100
            report += String(format: "%-20s %10.3fs %10.3fs %9.1f%%\n", "谱质心", accMetrics.spectralCentroidTime, akMetrics.spectralCentroidTime, diff)
        }
        
        if accMetrics.fftTime > 0 || akMetrics.fftTime > 0 {
            let diff = abs(accMetrics.fftTime - akMetrics.fftTime) / min(accMetrics.fftTime, akMetrics.fftTime) * 100
            report += String(format: "%-20s %10.3fs %10.3fs %9.1f%%\n", "FFT", accMetrics.fftTime, akMetrics.fftTime, diff)
        }
        
        if accMetrics.mfccTime > 0 || akMetrics.mfccTime > 0 {
            let diff = abs(accMetrics.mfccTime - akMetrics.mfccTime) / min(accMetrics.mfccTime, akMetrics.mfccTime) * 100
            report += String(format: "%-20s %10.3fs %10.3fs %9.1f%%\n", "MFCC", accMetrics.mfccTime, akMetrics.mfccTime, diff)
        }
        
        report += "\n" + String(repeating: "=", count: 50)
        
        print(report)
        performanceComparison = report
        
        // 同时在控制台输出 Accelerate 和 AudioKit 的详细报告
        print("\n🔵 Accelerate 详细报告:")
        print(accMetrics.report)
        print("\n🟢 AudioKit 详细报告:")
        print(akMetrics.report)
    }
    
    // 特征提取完成
    private func onFeaturesExtracted(features: [AcousticFeatures], metrics: PerformanceMetrics? = nil) {
        self.features = features
        analysisProgress = 0.7
        
        // 执行段落检测
        let detector = SegmentDetector(features: features)
        detector.detectSegments()
        self.segmentDetector = detector
        self.segments = detector.segments
        
        // 计算统计信息
        updateStatistics()
        
        analysisProgress = 1.0
        isAnalyzing = false
        showAnalysisWindow = true
        
        print("✓ 分析完成: \(features.count)个音频帧, \(segments.count)个段落")
    }
    
    // 更新统计信息
    private func updateStatistics() {
        totalSilenceDuration = segments
            .filter { $0.type == .silence }
            .reduce(0) { $0 + $1.duration }
        
        totalSpeechDuration = segments
            .filter { $0.type == .speech }
            .reduce(0) { $0 + $1.duration }
        
        totalMusicDuration = segments
            .filter { $0.type == .music }
            .reduce(0) { $0 + $1.duration }
        
        if !features.isEmpty {
            averageEnergy = features.map { $0.energy }.reduce(0, +) / Float(features.count)
            averageZCR = features.map { $0.zcr }.reduce(0, +) / Float(features.count)
        }
    }
}
