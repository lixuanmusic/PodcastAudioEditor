import Foundation
import Accelerate

/// 动态音量平衡增益包络计算器
class GainEnvelopeCalculator {
    // MARK: - 配置参数
    private let targetRMS: Float = -20.0  // 目标RMS电平（dB）
    private let minGain: Float = -20.0    // 最小增益（dB）
    private let maxGain: Float = 20.0     // 最大增益（dB）

    // 平滑参数
    private let smoothingWindowSize: Int = 10  // 用于平滑的窗口大小（帧数）
    private let attackTime: Double = 0.05     // 攻击时间（秒）
    private let releaseTime: Double = 0.2     // 释放时间（秒）

    // MARK: - 计算增益包络
    /// 从音频特征计算增益包络曲线
    /// - Parameter features: 音频特征数组
    /// - Returns: 增益包络数组（dB）
    func calculateGainEnvelope(from features: [AcousticFeatures]) -> [Float] {
        guard !features.isEmpty else { return [] }

        print("🎚️  开始计算增益包络: \(features.count)帧")
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. 提取RMS能量
        let energyValues = features.map { $0.energy }

        // 2. 计算原始增益（使每帧补偿到目标RMS）
        var rawGains = calculateRawGains(from: energyValues)

        // 3. 应用平滑（减少突兀变化）
        rawGains = applySmoothingFilter(to: rawGains)

        // 4. 应用包络跟踪（攻击和释放）
        // 注意：不再传入feature.timestamp（这是时间值），而是使用固定的采样率44100
        let envelopeGains = applyEnvelopeTracking(to: rawGains)

        // 5. 限制增益范围
        let finalGains = limitGainRange(envelopeGains)

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("✅ 增益包络计算完成: \(String(format: "%.3f", duration))秒")
        print("📊 增益范围: [\(finalGains.min() ?? 0), \(finalGains.max() ?? 0)] dB")

        return finalGains
    }

    // MARK: - 私有方法

    /// 计算原始增益值（目标补偿到-14dB RMS）
    private func calculateRawGains(from energyValues: [Float]) -> [Float] {
        return energyValues.map { energy -> Float in
            // 增益 = 目标RMS - 当前能量
            // 正增益表示升高音量，负增益表示降低音量
            let rawGain = targetRMS - energy
            return rawGain
        }
    }

    /// 应用平滑过滤器（中值滤波 + 移动平均）
    private func applySmoothingFilter(to gains: [Float]) -> [Float] {
        guard !gains.isEmpty else { return [] }

        // 第一步：中值滤波（去除尖峰）
        let medianFiltered = applyMedianFilter(to: gains, windowSize: 3)

        // 第二步：移动平均（平滑变化）
        let movingAverage = applyMovingAverage(to: medianFiltered, windowSize: smoothingWindowSize)

        return movingAverage
    }

    /// 中值滤波
    private func applyMedianFilter(to gains: [Float], windowSize: Int) -> [Float] {
        let halfWindow = windowSize / 2
        var filtered = [Float]()

        for i in 0..<gains.count {
            let start = max(0, i - halfWindow)
            let end = min(gains.count - 1, i + halfWindow)
            let window = Array(gains[start...end]).sorted()
            filtered.append(window[window.count / 2])
        }

        return filtered
    }

    /// 移动平均滤波
    private func applyMovingAverage(to gains: [Float], windowSize: Int) -> [Float] {
        guard windowSize > 0 else { return gains }
        let halfWindow = windowSize / 2
        var averaged = [Float]()

        for i in 0..<gains.count {
            let start = max(0, i - halfWindow)
            let end = min(gains.count - 1, i + halfWindow)
            let window = gains[start...end]
            let average = window.reduce(0, +) / Float(window.count)
            averaged.append(average)
        }

        return averaged
    }

    /// 应用包络跟踪（动态响应，快速攻击，缓慢释放）
    private func applyEnvelopeTracking(to gains: [Float]) -> [Float] {
        guard !gains.isEmpty else { return [] }

        // 固定使用hopSize=768，样本率44100Hz的配置
        let estimatedSampleRate = 44100.0
        let hopSize = 768.0
        let frameTime = hopSize / estimatedSampleRate  // 每帧的时间

        let attackCoeff = Float(frameTime / attackTime)
        let releaseCoeff = Float(frameTime / releaseTime)

        var envelope = [Float]()
        var envelopeValue = gains[0]

        for gain in gains {
            if gain > envelopeValue {
                // 攻击（快速响应）
                envelopeValue += (gain - envelopeValue) * min(1.0, attackCoeff)
            } else {
                // 释放（缓慢恢复）
                envelopeValue += (gain - envelopeValue) * min(1.0, releaseCoeff)
            }
            envelope.append(envelopeValue)
        }

        return envelope
    }

    /// 限制增益在允许范围内
    private func limitGainRange(_ gains: [Float]) -> [Float] {
        return gains.map { gain in
            max(minGain, min(maxGain, gain))
        }
    }
}

/// 增益包络曲线数据模型
struct GainEnvelopeData {
    let timestamps: [Double]           // 时间戳（秒）
    let gains: [Float]                 // 增益值（dB）
    let energyValues: [Float]          // 原始能量值（用于可视化对比）
    let totalDuration: Double          // 音频总时长（秒） - 用于正确的时间映射

    var frameCount: Int {
        return gains.count
    }

    var durationSeconds: Double {
        // 使用显式的总时长，确保与波形时长一致
        return totalDuration
    }

    /// 获取指定时间范围的增益曲线数据
    func getGainsInTimeRange(start: Double, end: Double) -> [Float] {
        let startIdx = timestamps.firstIndex { $0 >= start } ?? 0
        let endIdx = timestamps.lastIndex { $0 <= end } ?? timestamps.count - 1

        guard startIdx <= endIdx else { return [] }
        return Array(gains[startIdx...endIdx])
    }
}
