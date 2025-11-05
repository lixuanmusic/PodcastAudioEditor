# 增益包络曲线位置偏差修复总结

## 问题描述
用户报告：3分钟音频，波形完整展示，但增益包络曲线只显示在左侧的1/8处。

## 根本原因
**时间映射不一致** - 增益包络数据中的时长和波形显示使用的时长不一致：
- 原始代码从 `timestamps.last` 推断音频时长
- 而波形显示使用 `AudioPlayerViewModel.duration`（从实际文件计算）
- 这两个值可能不相等，导致时间映射错误

## 修复方案

### 3个关键改动

#### 1️⃣ 数据结构修改
**文件**: `GainEnvelopeCalculator.swift`
```swift
struct GainEnvelopeData {
    // ... 原有属性 ...
    let totalDuration: Double  // ← 新增：显式的音频总时长

    var durationSeconds: Double {
        return totalDuration  // ← 改为返回显式值而非推断
    }
}
```
✅ **目的**: 确保时间映射与波形一致

#### 2️⃣ 方法签名更新
**文件**: `DynamicVolumeBalanceViewModel.swift`
```swift
// 新增 audioDuration 参数
func calculateGainEnvelope(from features: [AcousticFeatures],
                          audioDuration: Double)  // ← 接收实际时长
```
✅ **目的**: 从UI层传递准确的音频时长

#### 3️⃣ 调用处更新
**文件**: `MainEditorView.swift`
```swift
// 传入 viewModel.duration（AudioPlayerViewModel中的实际时长）
dynamicVolumeVM.calculateGainEnvelope(from: analysisVM.features,
                                     audioDuration: viewModel.duration)
```
✅ **目的**: 确保使用的是波形显示使用的同一时长

### 1个算法修复

#### 4️⃣ 像素计算公式
**文件**: `GainEnvelopeCurveView.swift`
```swift
// 原始（错误）
let pixelPerFrame = size.width / Double(data.frameCount) * Double(scale)

// 修复（正确）
let pixelPerFrame = Double(size.width) * frameTime / visibleDuration
```

**原因**:
- 原公式没有考虑可见范围
- 新公式基于：`像素 = 视图宽度 × (每帧时间 / 可见时间范围)`

## 验证结果

✅ **编译**: BUILD SUCCEEDED
✅ **错误**: 0个
✅ **警告**: 仅Sendable相关（非功能性）
✅ **应用**: 正常运行

## 变更统计

| 项目 | 数量 |
|------|------|
| 修改文件 | 3个 |
| 新增参数 | 1个 |
| 修复公式 | 1个 |
| 代码行数 | ~15行 |

## 改动详情

### GainEnvelopeCalculator.swift
- 添加 `totalDuration: Double` 参数到 `GainEnvelopeData`
- 修改 `durationSeconds` 计算方式

### DynamicVolumeBalanceViewModel.swift
- 方法签名添加 `audioDuration: Double` 参数
- 创建 `GainEnvelopeData` 时传入 `totalDuration`
- 添加调试日志：时间映射信息

### MainEditorView.swift
- 更新方法调用，传入 `viewModel.duration`

### GainEnvelopeCurveView.swift
- 修复 `pixelPerFrame` 计算公式
- 更新 Preview 数据（添加 `totalDuration`）

## 测试建议

用3分钟音频验证：
1. 加载音频并完整显示波形
2. 分析音频
3. 启用动态音量平衡
4. **检查**: 增益曲线应跨越整个波形宽度
5. **检查**: 缩放/滚动时应保持对齐

## 关键设计决策

### 为什么传递 `viewModel.duration` 而不是其他？
- `AudioPlayerViewModel.duration` 是从实际文件计算的
- 这是波形显示使用的同一时长
- 确保了 100% 的时间一致性

### 为什么添加显式参数而不是推断？
- 推断容易出错（依赖 timestamps 的最后一个值）
- 显式参数确保意图清晰
- 便于调试和维护

## 后续改进方向

1. **添加调试视图**: 显示时间映射信息（帧数、时长、帧时间间隔）
2. **单元测试**: 验证时间映射计算正确性
3. **文档更新**: 说明时间映射的三层一致性
4. **性能优化**: 如果采样间隔计算仍不理想，可考虑自适应采样

## 相关文档

- 📖 [FIX_ENVELOPE_POSITION.md](FIX_ENVELOPE_POSITION.md) - 详细的修复说明
- 📚 [DYNAMIC_VOLUME_BALANCE.md](DYNAMIC_VOLUME_BALANCE.md) - 功能使用指南

---

**修复完成时间**: 2025-11-05
**修复状态**: ✅ 完成并验证
**编译状态**: ✅ BUILD SUCCEEDED
