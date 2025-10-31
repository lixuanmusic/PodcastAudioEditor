import Foundation

// 特征提取器协议
protocol FeatureExtractorProtocol {
    var features: [AcousticFeatures] { get }
    var isProcessing: Bool { get }
    var performanceMetrics: PerformanceMetrics { get }
    var extractorName: String { get }
    
    func extractFeaturesAsync(onProgress: @escaping (Double) -> Void, completion: @escaping () -> Void)
}

// 提取器类型
enum FeatureExtractorType: String, CaseIterable {
    case accelerate = "Accelerate"
    case audioKit = "AudioKit"
    
    var description: String {
        switch self {
        case .accelerate:
            return "Accelerate框架（当前实现）"
        case .audioKit:
            return "AudioKit框架"
        }
    }
}
