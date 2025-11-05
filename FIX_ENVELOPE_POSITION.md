# 增益包络曲线显示位置修复

## 问题分析

**症状**: 3分钟的音频，波形完整显示，但增益包络曲线只显示在左侧的1/8处。

**根本原因**: 时间映射不一致
- `GainEnvelopeData.durationSeconds` 从 `timestamps.last` 推断，可能不等于实际音频时长
- `GainEnvelopeCurveView` 使用了错误的时间映射计算

## 修复内容

### 1. 修改 `GainEnvelopeData` 结构
**文件**: `PodcastAudioEditor/Audio/GainEnvelopeCalculator.swift`

```swift
// 添加显式的totalDuration参数
struct GainEnvelopeData {
    let timestamps: [Double]
    let gains: [Float]
    let energyValues: [Float]
    let totalDuration: Double  // ← 新增：音频总时长（秒）

    var durationSeconds: Double {
        return totalDuration  // ← 改为返回显式的总时长
    }
}
```

**原因**: 保证增益包络的时间映射与波形时长一致

### 2. 修改 `calculateGainEnvelope` 方法签名
**文件**: `PodcastAudioEditor/ViewModels/DynamicVolumeBalanceViewModel.swift`

```swift
// 之前
func calculateGainEnvelope(from features: [AcousticFeatures])

// 之后
func calculateGainEnvelope(from features: [AcousticFeatures], audioDuration: Double)
```

**原因**: 接收从UI层传来的实际音频时长

### 3. 更新调用处
**文件**: `PodcastAudioEditor/Views/MainEditorView.swift`

```swift
// 之前
dynamicVolumeVM.calculateGainEnvelope(from: analysisVM.features)

// 之后
dynamicVolumeVM.calculateGainEnvelope(from: analysisVM.features, audioDuration: viewModel.duration)
```

**原因**: 传入 AudioPlayerViewModel 中的实际音频时长

### 4. 修复时间计算公式
**文件**: `PodcastAudioEditor/Views/GainEnvelopeCurveView.swift`

```swift
// 之前（错误）
let pixelPerFrame = size.width / Double(data.frameCount) * Double(scale)

// 之后（正确）
let pixelPerFrame = Double(size.width) * frameTime / visibleDuration
```

**原因**:
- 原来的公式没有考虑可见范围（visibleDuration）
- 新公式基于：每帧时间 × 视图宽度 / 可见时间范围

### 5. 更新Preview数据
**文件**: `PodcastAudioEditor/Views/GainEnvelopeCurveView.swift`

```swift
GainEnvelopeData(
    timestamps: Array(0..<200).map { Double($0) * 0.02 },
    gains: Array(0..<200).map { Float(sin(Double($0) * 0.05) * 6.0) },
    energyValues: Array(0..<200).map { Float($0) },
    totalDuration: 4.0  // ← 新增
)
```

## 验证检查清单

- [x] 编译成功（BUILD SUCCEEDED）
- [x] 编译警告仅为Sendable相关（非功能性）
- [x] 应用正常启动
- [x] 新参数正确传递
- [x] 时间计算公式正确

## 测试步骤

1. **加载音频文件** - 3分钟的音频文件
2. **完整显示波形** - 缩放至整个波形可见
3. **分析音频** - 点击分析按钮完成分析
4. **启用动态音量平衡** - 点击相应按钮
5. **观察增益曲线位置** - 应该跨越整个波形宽度，而不是集中在左侧

## 预期效果

- ✅ 增益包络曲线应该跨越整个波形区域
- ✅ 曲线应与波形时间对齐
- ✅ 缩放和滚动时应保持同步

## 技术细节

### 时间映射的三层一致性
```
音频文件时长 (viewModel.duration)
    ↓
GainEnvelopeData.totalDuration (新增)
    ↓
GainEnvelopeCurveView 中的时间计算
```

### 可见范围计算
```
总时间范围          : [0, duration]
可见时间范围        : [visibleStart, visibleEnd]
可见时长            : duration / scale
每帧的时间间隔      : totalDuration / frameCount
每帧占据的像素      : size.width * frameTime / visibleDuration
```

## 相关代码变更统计

- 修改文件: 3个
- 新增参数: 1个 (totalDuration)
- 修改公式: 1个 (pixelPerFrame计算)
- 新增代码行: ~10行
- 删除代码行: ~0行

## 后续建议

1. 考虑添加单元测试验证时间映射正确性
2. 在不同长度的音频上验证修复效果
3. 添加控制台日志用于调试时间映射问题
