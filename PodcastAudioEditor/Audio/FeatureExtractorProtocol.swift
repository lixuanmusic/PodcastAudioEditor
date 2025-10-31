import Foundation
import AVFoundation

// 特征提取器协议
protocol FeatureExtractorProtocol {
    var features: [AcousticFeatures] { get }
    var isProcessing: Bool { get }
    var performanceMetrics: PerformanceMetrics { get }
    var extractorName: String { get }
    
    func extractFeaturesAsync(onProgress: @escaping (Double) -> Void, completion: @escaping () -> Void)
}
