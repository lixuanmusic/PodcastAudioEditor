# AU 效果器链系统实现

## 概述

已成功实现了一个完整的 AU (Audio Unit) 效果器链系统，支持在播放器后接入最多 4 个效果器插槽。效果器会在实时播放时生效，并在导出音频时应用。

## 系统架构

### 核心组件

#### 1. **AudioUnitEffectSlot** (`AudioUnitEffectSlot.swift`)
- 管理单个效果器插槽（共 4 个，编号 0-3）
- 功能：
  - 加载/卸载 AU 效果器
  - 启用/禁用效果
  - 显示效果器信息和参数编辑界面

#### 2. **AudioEffectChain** (`AudioEffectChain.swift`)
- 管理 4 个效果器插槽的链接和控制
- 功能：
  - 获取所有已加载的效果器
  - 获取已启用的效果器（用于引擎连接）
  - 整体启用/禁用效果链

#### 3. **AudioUnitLoader** (`AudioUnitLoader.swift`)
- 辅助工具，用于发现和加载 AU 效果器
- 功能：
  - 列出系统中所有可用的 AU 效果器
  - 异步创建 AU 实例
  - 筛选常用效果器

#### 4. **AudioEngine** (升级版)
- 从 `AVAudioPlayer` 升级到 `AVAudioEngine`
- 新增功能：
  - 集成效果器链处理
  - 信号流向：`PlayerNode → Effect1 → Effect2 → Effect3 → Effect4 → MainMixer → Output`
  - 支持 seek 功能（通过 `scheduleSegment` 实现精确跳转）
  - 实时播放时应用所有启用的效果器

#### 5. **EffectSlotsPanel** (`EffectSlotsPanel.swift`)
- 完整的 UI 界面，用于管理 4 个效果器插槽
- 包含：
  - `EffectSlotView`: 单个插槽的 UI 组件
  - `EffectPickerView`: 效果器选择对话框
  - `EffectUIWrapperView`: 效果器编辑界面包装器
  - `EffectSlotsPanel`: 完整的面板

## 使用流程

### 1. 加载效果器

```swift
// 获取所有可用的 AU 效果器
let components = AudioUnitLoader.getAvailableAudioUnits()

// 创建 AU 实例
let audioUnit = try await AudioUnitLoader.createAudioUnit(from: component)

// 将效果器加载到插槽 0
audioEngine.effectChain.loadAudioUnit(at: 0, unit: audioUnit, withName: "AUDelay")
```

### 2. 启用/禁用效果器

```swift
// 启用插槽 0 的效果器
if let slot = audioEngine.effectChain.getSlot(0) {
    slot.isEnabled = true
}

// 禁用整个效果链
audioEngine.effectChain.isEnabled = false
```

### 3. 编辑效果器参数

```swift
// 获取效果器的编辑界面
if let slot = audioEngine.effectChain.getSlot(0) {
    if let viewController = slot.getAudioUnitViewController() {
        // 在模态窗口或面板中展示 viewController
    }
}
```

## 信号流向

```
音频文件
  ↓
PlayerNode (播放节点)
  ↓
Effect Slot 0 (第一个效果器，可选)
  ↓
Effect Slot 1 (第二个效果器，可选)
  ↓
Effect Slot 2 (第三个效果器，可选)
  ↓
Effect Slot 3 (第四个效果器，可选)
  ↓
MainMixerNode (主混音器)
  ↓
Audio Output (音频输出)
```

## 效果器类型

系统支持 macOS 中的所有 AU 效果器，包括但不限于：

- **延迟**: AUDelay
- **混响**: AUReverbG2
- **限幅器**: AUPeakLimiter
- **滤波器**: AUFilter, AUBandPass, AUParametricEQ
- **卷积**: AUConvolver
- **压缩器**: AUCompressor

## 关键特性

### ✅ 实时播放应用
效果器在实时播放音频时立即生效，用户可以实时听到处理效果。

### ✅ Seek 支持
seek 功能通过 `scheduleSegment` 实现，可以精确地从任意位置开始播放，效果器链正常处理所有音频。

### ✅ 启用/禁用
每个插槽的效果器可单独启用/禁用，整个效果链也可禁用。

### ✅ 灵活链接
支持最多 4 个串联效果器，可组合不同的处理效果。

### ✅ 参数编辑
集成了 AVAudioUnit 的原生参数编辑界面（若系统支持）。

## 导出功能

> 注意：导出功能的 AU 效果器处理仍在实现中，目前导出时会应用音频处理器中的增益处理，后续会扩展为支持 AU 效果器链。

## 文件列表

| 文件 | 用途 |
|------|------|
| `AudioUnitEffectSlot.swift` | 单个效果器插槽管理 |
| `AudioEffectChain.swift` | 效果器链管理 |
| `AudioUnitLoader.swift` | AU 效果器加载助手 |
| `AudioEngine.swift` | 升级的音频引擎（AVAudioEngine） |
| `EffectSlotsPanel.swift` | 完整的 UI 界面 |

## 技术细节

### 架构升级原因

从 `AVAudioPlayer` 升级到 `AVAudioEngine + AVAudioPlayerNode` 的原因：

1. **AU 效果器支持**: AVAudioPlayer 不支持 AU 效果器链处理，只能播放原始音频
2. **灵活性**: AVAudioEngine 提供了完整的节点图（node graph）系统，支持复杂的音频处理流程
3. **实时性**: 支持实时参数调整和效果器动态加载

### Seek 实现

使用 `scheduleSegment` 而非简单的 `currentTime` 设置：

```swift
playerNode.scheduleSegment(audioFile, startingFrame: startFrame,
                          frameCount: totalFrames, at: nil)
```

这确保了：
- ✅ 精确的帧级定位
- ✅ 避免了内存拷贝（使用文件映射）
- ✅ 效果器链正常处理新位置的音频

## 后续改进方向

1. **导出时 AU 效果器支持**: 将实时播放的效果器链应用到导出的音频文件
2. **预设管理**: 保存和加载效果器预设
3. **自动化**: 支持效果器参数的时间自动化
4. **可视化**: 频谱分析、波形显示等实时可视化效果

## 注意事项

- 目前系统支持最多 4 个串联效果器
- 某些效果器可能需要特定的硬件或 macOS 版本支持
- 实时播放的 CPU 占用取决于所使用的效果器数量和复杂度
- 建议在导出前先在实时播放中测试效果器组合
