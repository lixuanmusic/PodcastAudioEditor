import Foundation

// 段落类型枚举
enum SegmentType {
    case silence       // 静音
    case speech        // 语音
    case music         // 音乐
    case noise         // 噪音
    case unknown       // 未知
}

// 段落结构
struct Segment {
    let startTime: Double
    let endTime: Double
    let type: SegmentType
    let confidence: Float  // 置信度 0-1
    let features: AcousticFeatures?
    
    var duration: Double { endTime - startTime }
    
    var description: String {
        let typeStr: String
        switch type {
        case .silence: typeStr = "静音"
        case .speech: typeStr = "语音"
        case .music: typeStr = "音乐"
        case .noise: typeStr = "噪音"
        case .unknown: typeStr = "未知"
        }
        return "\(typeStr) [\(String(format: "%.2f", startTime))s - \(String(format: "%.2f", endTime))s] (置信度: \(String(format: "%.0f", confidence*100))%)"
    }
}

final class SegmentDetector {
    private let features: [AcousticFeatures]
    private let hopSize: Int = 768  // 与AcousticFeatureExtractor保持一致（约17.4ms @ 44100Hz，25%重叠）
    private let sampleRate: Double = 44100  // 默认采样率
    
    var segments: [Segment] = []
    
    init(features: [AcousticFeatures]) {
        self.features = features
    }
    
    // 检测所有类型的段落
    func detectSegments() {
        segments.removeAll()
        
        // 1. 检测静音段
        detectSilence()
        
        // 2. 在非静音段检测音乐和语音
        detectMusicAndSpeech()
        
        print("✓ 段落检测完成: 共\(segments.count)个段落")
    }
    
    // 检测静音段（基于能量阈值）
    private func detectSilence() {
        let energyThreshold: Float = -40.0  // dB
        let minSilenceDuration: Double = 0.5  // 秒（最小静音时长）
        
        var inSilence = false
        var silenceStartIdx = 0
        
        for (idx, feature) in features.enumerated() {
            let isSilent = feature.energy < energyThreshold
            
            if isSilent && !inSilence {
                // 进入静音
                inSilence = true
                silenceStartIdx = idx
            } else if !isSilent && inSilence {
                // 离开静音
                let duration = Double(idx - silenceStartIdx) * Double(hopSize) / sampleRate
                if duration >= minSilenceDuration {
                    let startTime = Double(silenceStartIdx) * Double(hopSize) / sampleRate
                    let endTime = Double(idx) * Double(hopSize) / sampleRate
                    let segment = Segment(
                        startTime: startTime,
                        endTime: endTime,
                        type: .silence,
                        confidence: 0.9,
                        features: nil
                    )
                    segments.append(segment)
                }
                inSilence = false
            }
        }
        
        // 处理末尾的静音
        if inSilence {
            let duration = Double(features.count - silenceStartIdx) * Double(hopSize) / sampleRate
            if duration >= minSilenceDuration {
                let startTime = Double(silenceStartIdx) * Double(hopSize) / sampleRate
                let endTime = Double(features.count) * Double(hopSize) / sampleRate
                let segment = Segment(
                    startTime: startTime,
                    endTime: endTime,
                    type: .silence,
                    confidence: 0.9,
                    features: nil
                )
                segments.append(segment)
            }
        }
        
        print("📍 检测到\(segments.count)个静音段")
    }
    
    // 检测音乐和语音（基于特征对比）
    private func detectMusicAndSpeech() {
        let zcrThreshold: Float = 0.1      // 零交叉率阈值
        let energyThreshold: Float = -40.0 // 能量阈值
        let minSegmentDuration: Double = 0.3  // 最小段落时长
        
        var currentType: SegmentType? = nil
        var segmentStartIdx = 0
        var typeConfidences: [Float] = []
        
        for (idx, feature) in features.enumerated() {
            // 跳过静音
            if feature.energy < energyThreshold {
                if currentType != nil {
                    addSegmentIfValid(
                        type: currentType!,
                        startIdx: segmentStartIdx,
                        endIdx: idx,
                        confidences: typeConfidences,
                        minDuration: minSegmentDuration
                    )
                    currentType = nil
                    typeConfidences.removeAll()
                }
                continue
            }
            
            // 判断当前帧的类型
            let frameType = detectFrameType(feature: feature)
            
            if frameType == currentType {
                // 继续当前类型
                typeConfidences.append(feature.energy)
            } else {
                // 类型改变，保存前一个段落
                if currentType != nil {
                    addSegmentIfValid(
                        type: currentType!,
                        startIdx: segmentStartIdx,
                        endIdx: idx,
                        confidences: typeConfidences,
                        minDuration: minSegmentDuration
                    )
                }
                
                currentType = frameType
                segmentStartIdx = idx
                typeConfidences = [feature.energy]
            }
        }
        
        // 处理末尾段落
        if currentType != nil {
            addSegmentIfValid(
                type: currentType!,
                startIdx: segmentStartIdx,
                endIdx: features.count,
                confidences: typeConfidences,
                minDuration: minSegmentDuration
            )
        }
    }
    
    // 添加有效的段落（超过最小时长）
    private func addSegmentIfValid(
        type: SegmentType,
        startIdx: Int,
        endIdx: Int,
        confidences: [Float],
        minDuration: Double
    ) {
        let duration = Double(endIdx - startIdx) * Double(hopSize) / sampleRate
        guard duration >= minDuration else { return }
        
        let startTime = Double(startIdx) * Double(hopSize) / sampleRate
        let endTime = Double(endIdx) * Double(hopSize) / sampleRate
        
        // 计算置信度（基于能量稳定性）
        let avgEnergy = confidences.reduce(0, +) / Float(confidences.count)
        let variance = confidences.map { pow($0 - avgEnergy, 2) }.reduce(0, +) / Float(confidences.count)
        let confidence = max(0.5, 1.0 - sqrt(variance) / 50.0)
        
        let segment = Segment(
            startTime: startTime,
            endTime: endTime,
            type: type,
            confidence: confidence,
            features: features.first { abs($0.timestamp - startTime) < 0.1 }
        )
        
        segments.append(segment)
    }
    
    // 识别单帧的类型
    // 策略：在播客场景下，默认语音，只有非常明确且一致的特征才判为音乐
    private func detectFrameType(feature: AcousticFeatures) -> SegmentType {
        // ZCR是区分音乐和语音的关键指标：
        // - 语音：ZCR通常较高（0.08-0.4），因为语音有更多高频变化和辅音
        // - 音乐：ZCR通常较低（0.03-0.10），因为音乐信号更平滑
        
        // 检查ZCR是否可用
        if feature.zcr > 0 {
            // 只有ZCR极低（< 0.03）且同时满足其他条件才判为音乐
            // 这样可以避免将低ZCR的语音片段误判为音乐
            if feature.zcr < 0.03 {
                // 需要谱质心也低（确认是低频内容，而不是静音后的短暂低能量语音）
                if feature.spectralCentroid > 0 && feature.spectralCentroid < 2000 {
                    // ZCR极低 + 谱质心低 → 很可能是音乐（低频音乐或背景音乐）
                    return .music
                }
                // 如果谱质心不可用，需要MFCC极其稳定才判为音乐
                if feature.spectralCentroid == 0 && !feature.mfccValues.isEmpty {
                    let mfccMean = feature.mfccValues.reduce(0) { $0 + abs($1) } / Float(feature.mfccValues.count)
                    // ZCR极低 + MFCC极稳定（且能量不是太低） → 可能是音乐
                    if mfccMean < 2.0 && feature.energy > -50 {
                        return .music
                    }
                }
            }
            
            // ZCR >= 0.03 → 判为语音
            // 大多数语音的ZCR在0.08-0.25之间
            // 即使有些语音片段ZCR较低（0.03-0.08），也应该判为语音（保守策略）
            return .speech
        }
        
        // ZCR不可用时（不应该发生，fast模式下应该提取ZCR）
        // 默认判为语音
        return .speech
    }
}
