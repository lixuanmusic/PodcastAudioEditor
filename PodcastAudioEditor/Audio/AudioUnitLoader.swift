import AVFoundation

// AU 效果器加载助手
class AudioUnitLoader {
    // 获取所有可用的 AU 效果器
    static func getAvailableAudioUnits() -> [AVAudioUnitComponent] {
        let components = AVAudioUnitComponentManager.shared().components(
            matching: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )
        return components
    }

    // 根据组件创建 AU 效果器
    static func createAudioUnit(from component: AVAudioUnitComponent) async throws -> AVAudioUnit {
        return try await AVAudioUnit.instantiate(with: component.audioComponentDescription)
    }

    // 常用的预设效果器列表
    static func getCommonEffectPresets() -> [(name: String, description: AVAudioUnitComponent)] {
        let components = getAvailableAudioUnits()

        // 筛选常用的效果器
        let effectNames = [
            "AUDelay", "AUReverbG2", "AUPeakLimiter", "AUFilter",
            "AUConvolver", "AUBandPass", "AUParametricEQ", "AUCompressor"
        ]

        var presets: [(name: String, description: AVAudioUnitComponent)] = []

        for component in components {
            let name = component.name
            if effectNames.contains(where: { name.contains($0) }) {
                presets.append((name: name, description: component))
            }
        }

        return presets
    }
}

