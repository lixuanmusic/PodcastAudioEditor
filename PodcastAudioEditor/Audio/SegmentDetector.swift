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
    private func detectFrameType(feature: AcousticFeatures) -> SegmentType {
        // 分类逻辑（优先级从高到低）：
        // 1. 使用ZCR（如果可用）- 最可靠的指标
        // 2. 使用MFCC辅助判断（如果ZCR不可用或不确定）
        // 3. 默认语音（播客以语音为主）
        
        // 检查ZCR是否可用（在fast模式下应该有）
        if feature.zcr > 0 {
            // ZCR高 → 语音（语音有更多高频成分）
            if feature.zcr > 0.15 {
                return .speech
            }
            // ZCR很低 → 可能是音乐（音乐通常更平滑）
            if feature.zcr < 0.08 {
                // 进一步用MFCC确认
                if feature.spectralCentroid > 0 && feature.spectralCentroid < 3000 {
                    return .music
                }
                // 如果谱质心不可用，使用MFCC能量稳定性判断
                if feature.spectralCentroid == 0 && !feature.mfccValues.isEmpty {
                    // MFCC[0]是能量，如果能量较高且稳定（通过MFCC系数变化判断）
                    let mfccVariance = feature.mfccValues.reduce(0) { $0 + abs($1) } / Float(feature.mfccValues.count)
                    if mfccVariance < 5.0 {  // 音乐通常MFCC变化较小
                        return .music
                    }
                }
                // 默认：低ZCR但不确定时，倾向于语音（播客主要是语音）
                return .speech
            }
            // ZCR中等（0.08-0.15）：通常是语音
            return .speech
        }
        
        // ZCR不可用时，使用MFCC判断
        if !feature.mfccValues.isEmpty {
            // MFCC系数变化大 → 语音（语音更复杂）
            let mfccVariance = feature.mfccValues.reduce(0) { $0 + abs($1) } / Float(feature.mfccValues.count)
            if mfccVariance < 3.0 {
                return .music
            }
        }
        
        // 默认返回语音（播客场景）
        return .speech
    }
}
