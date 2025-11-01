import SwiftUI
import AVFoundation

// 单个效果器插槽 UI
struct EffectSlotView: View {
    @ObservedObject var slot: AudioUnitEffectSlot
    @ObservedObject var effectChain: AudioEffectChain
    @State private var showEffectPicker = false
    @State private var showEffectUI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 插槽标题和启用开关
            HStack {
                Text("插槽 \(slot.slotIndex + 1)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("", isOn: $slot.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(slot.audioUnit == nil)  // 没有加载效果器时禁用开关
            }

            // 效果器名称
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.effectName)
                        .font(.caption)
                        .fontWeight(.medium)

                    if !slot.effectTypeDescription.isEmpty {
                        Text(slot.effectTypeDescription)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 按钮组
                HStack(spacing: 4) {
                    // 打开效果器 UI 按钮
                    if slot.audioUnit != nil {
                        Button {
                            showEffectUI = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("编辑效果器参数")
                    }

                    // 加载效果器按钮
                    Button {
                        showEffectPicker = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("选择效果器")

                    // 卸载效果器按钮
                    if slot.audioUnit != nil {
                        Button {
                            // 通过 AudioEffectChain 卸载，确保触发回调
                            effectChain.unloadAudioUnit(at: slot.slotIndex)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("卸载效果器")
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(4)
        .sheet(isPresented: $showEffectPicker) {
            EffectPickerView(slot: slot, effectChain: effectChain, isPresented: $showEffectPicker)
        }
        .sheet(isPresented: $showEffectUI) {
            EffectUIWrapperView(slot: slot, isPresented: $showEffectUI)
        }
    }
}

// 效果器选择器
struct EffectPickerView: View {
    @ObservedObject var slot: AudioUnitEffectSlot
    @ObservedObject var effectChain: AudioEffectChain
    @Binding var isPresented: Bool
    @State private var selectedComponent: AVAudioUnitComponent?
    @State private var isLoading = false

    // 获取所有可用的 AU 效果器并去重
    var components: [AVAudioUnitComponent] {
        let allComponents = AudioUnitLoader.getAvailableAudioUnits()
        // 按 name + manufacturer 去重
        var seen = Set<String>()
        var uniqueComponents: [AVAudioUnitComponent] = []
        for component in allComponents {
            let key = "\(component.name ?? "")-\(component.manufacturerName ?? "")"
            if !seen.contains(key) {
                seen.insert(key)
                uniqueComponents.append(component)
            }
        }
        return uniqueComponents.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    var body: some View {
        VStack {
            HStack {
                Text("选择效果器")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    isPresented = false
                }
            }
            .padding()

            if components.isEmpty {
                VStack {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("未找到可用的效果器")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(components, id: \.self) { component in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(component.name ?? "Unknown")
                                .font(.body)
                            Text("\(component.manufacturerName ?? "Unknown") - \(component.typeName ?? "Unknown")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("加载") {
                                Task {
                                    await loadEffect(component)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func loadEffect(_ component: AVAudioUnitComponent) async {
        isLoading = true
        do {
            let audioUnit = try await AudioUnitLoader.createAudioUnit(from: component)
            DispatchQueue.main.async {
                // 通过 AudioEffectChain 加载，确保触发回调
                effectChain.loadAudioUnit(at: slot.slotIndex, unit: audioUnit, withName: component.name ?? "Unknown")
                isPresented = false
                isLoading = false
            }
        } catch {
            print("❌ 加载效果器失败: \(error.localizedDescription)")
            DispatchQueue.main.async {
                isLoading = false
            }
        }
    }
}

// 效果器 UI 包装器
struct EffectUIWrapperView: View {
    @ObservedObject var slot: AudioUnitEffectSlot
    @Binding var isPresented: Bool

    var body: some View {
        VStack {
            HStack {
                Text("编辑 \(slot.effectName)")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    isPresented = false
                }
            }
            .padding()

            if let viewController = slot.getAudioUnitViewController() {
                EffectUIViewControllerRepresentable(viewController: viewController)
            } else {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("无法加载效果器编辑界面")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

// UIViewController 包装器
struct EffectUIViewControllerRepresentable: NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        return viewController
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
    }
}

// 音效链面板
struct EffectSlotsPanel: View {
    @ObservedObject var audioEngine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack {
                Text("AU 效果器链")
                    .font(.headline)

                Spacer()

                Toggle("启用", isOn: $audioEngine.effectChain.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider()

            // 4个插槽
            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    if let slot = audioEngine.effectChain.getSlot(index) {
                        EffectSlotView(slot: slot, effectChain: audioEngine.effectChain)
                    }
                }
            }
            .padding(.horizontal, 12)

            Divider()

            // 说明
            Text("信号流向: 播放器 → 插槽1 → 插槽2 → 插槽3 → 插槽4 → 输出")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .padding(8)
    }
}

#Preview {
    EffectSlotsPanel(audioEngine: AudioEngine.shared)
        .frame(height: 400)
}
