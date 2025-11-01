import AVFoundation

// 音效链管理器:管理4个 AU 效果器插槽
class AudioEffectChain: ObservableObject {
    // 4个效果器插槽
    @Published var slots: [AudioUnitEffectSlot] = []

    // 是否启用整个效果链
    @Published var isEnabled: Bool = true {
        didSet {
            if oldValue != isEnabled {
                print("🔄 效果链启用状态改变: \(isEnabled)")
                onEffectChainChanged?()
            }
        }
    }

    // 用于通知AudioEngine重新连接效果链
    var onEffectChainChanged: (() -> Void)?

    init() {
        // 初始化4个插槽
        slots = (0..<4).map { AudioUnitEffectSlot(slotIndex: $0) }

        // 为每个插槽设置启用状态改变回调
        for slot in slots {
            slot.onEnabledChanged = { [weak self] in
                self?.onEffectChainChanged?()
            }
        }
    }

    // 获取指定插槽
    func getSlot(_ index: Int) -> AudioUnitEffectSlot? {
        guard index >= 0 && index < slots.count else { return nil }
        return slots[index]
    }

    // 在指定插槽加载 AU 效果器
    func loadAudioUnit(at slotIndex: Int, unit: AVAudioUnit, withName name: String) {
        guard let slot = getSlot(slotIndex) else { return }
        slot.loadAudioUnit(unit, withName: name)
        // 触发重新连接
        onEffectChainChanged?()
    }

    // 卸载指定插槽的效果器
    func unloadAudioUnit(at slotIndex: Int) {
        guard let slot = getSlot(slotIndex) else { return }
        slot.unloadAudioUnit()
        // 触发重新连接
        onEffectChainChanged?()
    }

    // 获取所有已加载的效果器单元（用于引擎连接）
    func getLoadedAudioUnits() -> [AVAudioUnit] {
        return slots.compactMap { $0.audioUnit }
    }

    // 获取已加载且启用的效果器单元
    func getEnabledAudioUnits() -> [AVAudioUnit] {
        return slots.compactMap { slot in
            slot.isEnabled && slot.audioUnit != nil ? slot.audioUnit : nil
        }
    }

    // 打印效果链信息
    func printChainStatus() {
        print("=== 音效链状态 ===")
        for slot in slots {
            let status = slot.audioUnit != nil ? "✓ \(slot.effectName)" : "✗ 未加载"
            let enabled = slot.isEnabled ? "启用" : "禁用"
            print("插槽 \(slot.slotIndex): \(status) [\(enabled)]")
        }
        print("==================")
    }
}

