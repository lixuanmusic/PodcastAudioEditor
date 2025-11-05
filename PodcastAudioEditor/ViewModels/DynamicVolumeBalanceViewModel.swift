import SwiftUI
import Combine
import AVFoundation

/// 动态音量平衡视图模型
class DynamicVolumeBalanceViewModel: ObservableObject {
    // MARK: - 发布属性
    @Published var isEnabled: Bool = false
    @Published var envelopeData: GainEnvelopeData?
    @Published var isCalculating: Bool = false
    @Published var calculationProgress: Double = 0.0

    // 对 AudioEngine 的引用，用于加载效果器
    var audioEngine: AudioEngine?

    // MARK: - 私有属性
    private let calculator = GainEnvelopeCalculator()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化
    init() {}

    // MARK: - 公开方法

    /// 从音频特征计算增益包络，并自动加载AUPeakLimiter到插槽1
    /// - Parameters:
    ///   - features: 音频特征数组
    ///   - audioDuration: 音频总时长（秒），用于正确的时间映射
    func calculateGainEnvelope(from features: [AcousticFeatures], audioDuration: Double) {
        isCalculating = true
        calculationProgress = 0.0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 计算增益
            let gains = self.calculator.calculateGainEnvelope(from: features)

            // 构建增益包络数据
            let timestamps = features.map { $0.timestamp }
            let energyValues = features.map { $0.energy }

            let envelopeData = GainEnvelopeData(
                timestamps: timestamps,
                gains: gains,
                energyValues: energyValues,
                totalDuration: audioDuration  // 传入实际的音频时长
            )

            DispatchQueue.main.async {
                self.envelopeData = envelopeData
                self.isEnabled = true
                self.isCalculating = false
                self.calculationProgress = 0.0

                print("✅ 动态音量平衡: 增益包络已生成，共\(gains.count)个增益点")
                print("📊 时间映射: \(gains.count)帧 → \(String(format: "%.2f", audioDuration))秒")

                // 自动加载 AUPeakLimiter 到插槽1
                self.loadAUPeakLimiterToSlot1()
            }
        }
    }

    /// 自动加载 AUPeakLimiter 到插槽1
    private func loadAUPeakLimiterToSlot1() {
        guard let audioEngine = audioEngine else {
            print("❌ AudioEngine 未设置")
            return
        }

        // 获取插槽1
        guard let slot = audioEngine.effectChain.getSlot(0) else {
            print("❌ 无法获取插槽1")
            return
        }

        // 如果已经加载了效果器，先卸载
        if slot.audioUnit != nil {
            audioEngine.effectChain.unloadAudioUnit(at: 0)
        }

        // 异步加载 AUPeakLimiter
        Task {
            do {
                // 获取所有可用的 AU 效果器
                let allComponents = AudioUnitLoader.getAvailableAudioUnits()

                // 查找 AUPeakLimiter
                if let peakLimiterComponent = allComponents.first(where: { comp in
                    (comp.name ?? "").contains("PeakLimiter")
                }) {
                    let audioUnit = try await AudioUnitLoader.createAudioUnit(from: peakLimiterComponent)

                    DispatchQueue.main.async {
                        audioEngine.effectChain.loadAudioUnit(at: 0, unit: audioUnit, withName: "AUPeakLimiter")
                        print("✅ AUPeakLimiter 已自动加载到插槽1")
                    }
                } else {
                    print("⚠️  未找到 AUPeakLimiter 效果器")
                }
            } catch {
                print("❌ 加载 AUPeakLimiter 失败: \(error.localizedDescription)")
            }
        }
    }

    /// 重置增益包络
    func reset() {
        isEnabled = false
        envelopeData = nil
        isCalculating = false
        calculationProgress = 0.0
    }

    // MARK: - 增益查询方法

    /// 获取指定时刻的增益值
    /// - Parameter timestamp: 时间戳（秒）
    /// - Returns: 增益值（dB）
    func getGainAtTime(_ timestamp: Double) -> Float? {
        guard let data = envelopeData, !data.gains.isEmpty else { return nil }

        // 二分查找最近的时间戳
        let frameIndex = binarySearch(in: data.timestamps, for: timestamp)
        guard frameIndex >= 0 && frameIndex < data.gains.count else { return nil }

        return data.gains[frameIndex]
    }

    /// 获取时间范围内的增益值
    /// - Parameters:
    ///   - startTime: 开始时间
    ///   - endTime: 结束时间
    /// - Returns: 增益数组
    func getGainsInTimeRange(startTime: Double, endTime: Double) -> [Float] {
        return envelopeData?.getGainsInTimeRange(start: startTime, end: endTime) ?? []
    }

    // MARK: - 私有方法

    /// 二分查找
    private func binarySearch(in sortedArray: [Double], for target: Double) -> Int {
        var left = 0
        var right = sortedArray.count - 1

        while left < right {
            let mid = (left + right) / 2
            if sortedArray[mid] < target {
                left = mid + 1
            } else {
                right = mid
            }
        }

        return left
    }
}
