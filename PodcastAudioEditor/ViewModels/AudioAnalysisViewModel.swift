import SwiftUI
import Combine

class AudioAnalysisViewModel: ObservableObject {
    @Published var features: [AcousticFeatures] = []
    @Published var segments: [Segment] = []
    @Published var isAnalyzing = false
    @Published var analysisProgress: Double = 0.0
    @Published var showAnalysisWindow = false
    
    private var featureExtractor: AcousticFeatureExtractor?
    private var segmentDetector: SegmentDetector?
    
    // 统计信息
    @Published var totalSilenceDuration: Double = 0.0
    @Published var totalSpeechDuration: Double = 0.0
    @Published var totalMusicDuration: Double = 0.0
    @Published var averageEnergy: Float = 0.0
    @Published var averageZCR: Float = 0.0
    
    // 分析音频文件
    func analyzeAudioFile(url: URL) {
        guard let extractor = AcousticFeatureExtractor(audioFileURL: url) else {
            print("❌ 无法创建特征提取器")
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
                self?.onFeaturesExtracted(features: extractor.features)
            }
        )
    }
    
    // 特征提取完成
    private func onFeaturesExtracted(features: [AcousticFeatures]) {
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
