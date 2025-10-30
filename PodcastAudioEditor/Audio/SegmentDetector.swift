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
            
            // 判断当前帧的类型（每100帧打印一次特征用于调试）
            let frameType = detectFrameType(feature: feature)
            
            if idx % 100 == 0 {
                let mfccStr = feature.mfccValues.isEmpty ? "无" : "[\(feature.mfccValues.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: ","))]"
                print("🔍 [帧\(idx)] 类型=\(frameType == .speech ? "语音" : "音乐"), ZCR=\(String(format: "%.4f", feature.zcr)), 能量=\(String(format: "%.1f", feature.energy))dB, MFCC=\(mfccStr)")
            }
            
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
    // 策略：综合使用ZCR、MFCC和能量特征来判断
    private func detectFrameType(feature: AcousticFeatures) -> SegmentType {
        // 特征分析：
        // - 语音：ZCR较高(0.1-0.4), MFCC前几个系数变化大, 能量波动大
        // - 音乐：ZCR较低(0.03-0.15), MFCC系数较稳定, 能量较平稳
        
        var musicScore: Float = 0.0  // 音乐得分
        var speechScore: Float = 0.0  // 语音得分
        
        // 1. ZCR特征（权重：高）
        if feature.zcr > 0 {
            if feature.zcr < 0.05 {
                musicScore += 3.0  // ZCR极低，强烈倾向音乐
            } else if feature.zcr < 0.10 {
                musicScore += 1.0  // ZCR较低，轻微倾向音乐
            } else if feature.zcr > 0.15 {
                speechScore += 3.0  // ZCR高，强烈倾向语音
            } else {
                speechScore += 1.5  // ZCR中等，倾向语音
            }
        }
        
        // 2. MFCC特征（权重：高）
        if !feature.mfccValues.isEmpty && feature.mfccValues.count >= 4 {
            // MFCC[0]是能量，[1-3]反映频谱形状
            let mfcc1 = abs(feature.mfccValues[1])  // 通常语音的变化更大
            let mfcc2 = abs(feature.mfccValues[2])  
            let mfcc3 = abs(feature.mfccValues[3])
            
            // 计算MFCC的"平滑度"（前几个系数的绝对值）
            let mfccSmoothness = (mfcc1 + mfcc2 + mfcc3) / 3.0
            
            // 音乐：MFCC系数通常较小且稳定（平滑度高）
            // 语音：MFCC系数变化较大（平滑度低）
            if mfccSmoothness < 2.0 {
                musicScore += 2.0  // MFCC很平滑，倾向音乐
            } else if mfccSmoothness > 5.0 {
                speechScore += 2.0  // MFCC变化大，倾向语音
            }
            
            // MFCC能量分布特征
            // 音乐通常前几个MFCC系数（除了能量）相对均匀
            if feature.mfccValues.count > 3 {
                let mfccSlice = Array(feature.mfccValues[1...3])
                if let maxVal = mfccSlice.max(), let minVal = mfccSlice.min() {
                    let mfccRange = maxVal - minVal
                    if mfccRange < 3.0 {
                        musicScore += 1.0  // MFCC系数范围小，更可能是音乐
                    } else if mfccRange > 8.0 {
                        speechScore += 1.0  // MFCC系数范围大，更可能是语音
                    }
                }
            }
        }
        
        // 3. 能量特征（权重：中）
        // 音乐通常能量更稳定，语音能量波动更大
        // 这里我们主要用能量来排除静音，已经在上面处理了
        
        // 4. 谱质心特征（如果可用）
        if feature.spectralCentroid > 0 {
            if feature.spectralCentroid < 2000 && feature.zcr < 0.08 {
                musicScore += 2.0  // 低频 + 低ZCR → 音乐
            } else if feature.spectralCentroid > 4000 {
                speechScore += 1.0  // 高频 → 语音
            }
        }
        
        // 综合判断（采用保守策略：音乐需要明确的证据）
        // 如果musicScore显著高于speechScore，才判为音乐
        if musicScore > speechScore + 2.0 {
            return .music
        } else {
            // 默认判为语音（播客场景）
            return .speech
        }
    }
}
