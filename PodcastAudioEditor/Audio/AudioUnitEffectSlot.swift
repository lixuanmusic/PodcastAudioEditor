import AVFoundation
import AppKit
import ObjectiveC

// 单个 AU 效果器插槽
class AudioUnitEffectSlot: ObservableObject {
    // 槽位编号 (0-3)
    let slotIndex: Int

    // AU 效果器单元
    private(set) var audioUnit: AVAudioUnit?

    // 是否启用
    @Published var isEnabled: Bool = false

    // 效果器名称
    @Published var effectName: String = "未选择"

    // 效果器类型描述
    @Published var effectTypeDescription: String = ""

    init(slotIndex: Int) {
        self.slotIndex = slotIndex
    }

    // 加载 AU 效果器
    func loadAudioUnit(_ unit: AVAudioUnit, withName name: String) {
        self.audioUnit = unit
        self.effectName = name
        self.isEnabled = true

        // 获取效果器类型描述
        let auAudioUnit = unit.auAudioUnit
        let componentDescription = auAudioUnit.componentDescription
        self.effectTypeDescription = "\(componentDescription.componentType):\(componentDescription.componentSubType)"

        print("✓ 插槽 \(slotIndex) 已加载效果器: \(name)")
    }

    // 卸载 AU 效果器
    func unloadAudioUnit() {
        audioUnit = nil
        effectName = "未选择"
        effectTypeDescription = ""
        isEnabled = false
        print("✓ 插槽 \(slotIndex) 已卸载效果器")
    }

    // 获取 AU 效果器的参数视图控制器
    func getAudioUnitViewController() -> NSViewController? {
        guard let audioUnit = audioUnit else {
            return nil
        }

        // 创建通用的参数视图控制器
        return createGenericAudioUnitViewController(audioUnit)
    }

    // 创建通用的 AU 参数视图
    private func createGenericAudioUnitViewController(_ audioUnit: AVAudioUnit) -> NSViewController {
        let viewController = NSViewController()
        let scrollView = NSScrollView()
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = 12

        // 标题
        let titleLabel = NSTextField(labelWithString: "效果器: \(effectName)")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        stackView.addArrangedSubview(titleLabel)

        // 尝试显示参数信息
        let auAudioUnit = audioUnit.auAudioUnit
        let parameters = auAudioUnit.parameterTree?.allParameters ?? []
        let parameterCount = parameters.count

        if parameterCount > 0 {
            let paramInfo = NSTextField(wrappingLabelWithString: "此效果器具有 \(parameterCount) 个参数。请在下方调整参数值：")
            paramInfo.lineBreakMode = .byWordWrapping
            stackView.addArrangedSubview(paramInfo)

            // 添加参数控制
            for parameter in parameters.prefix(10) {
                // 参数名标签
                let paramNameLabel = NSTextField(labelWithString: parameter.displayName)
                paramNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                stackView.addArrangedSubview(paramNameLabel)

                // 参数行: 标签 + 滑块 + 值标签
                let paramRowView = NSView()
                paramRowView.translatesAutoresizingMaskIntoConstraints = false

                let minLabel = NSTextField(labelWithString: String(format: "%.2f", parameter.minValue))
                minLabel.font = NSFont.systemFont(ofSize: 10)
                minLabel.isEditable = false

                let maxLabel = NSTextField(labelWithString: String(format: "%.2f", parameter.maxValue))
                maxLabel.font = NSFont.systemFont(ofSize: 10)
                maxLabel.isEditable = false

                // 获取当前参数值
                let currentValue = parameter.value
                let valueLabel = NSTextField(labelWithString: String(format: "%.2f", currentValue))
                valueLabel.font = NSFont.systemFont(ofSize: 11)
                valueLabel.alignment = .center

                let slider = NSSlider(value: Double(currentValue), minValue: Double(parameter.minValue), maxValue: Double(parameter.maxValue), target: nil, action: nil)
                slider.translatesAutoresizingMaskIntoConstraints = false

                // 创建滑块值改变的目标
                class SliderHandler: NSObject {
                    let parameter: AUParameter
                    let audioUnit: AUAudioUnit
                    let valueLabel: NSTextField

                    init(_ parameter: AUParameter, _ audioUnit: AUAudioUnit, _ valueLabel: NSTextField) {
                        self.parameter = parameter
                        self.audioUnit = audioUnit
                        self.valueLabel = valueLabel
                    }

                    @objc func sliderChanged(_ sender: NSSlider) {
                        let newValue = AUValue(sender.doubleValue)
                        parameter.value = newValue
                        valueLabel.stringValue = String(format: "%.2f", newValue)
                    }
                }

                let handler = SliderHandler(parameter, auAudioUnit, valueLabel)
                slider.target = handler
                slider.action = #selector(SliderHandler.sliderChanged(_:))

                // 保存handler引用以防止被释放
                objc_setAssociatedObject(slider, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

                paramRowView.addSubview(minLabel)
                paramRowView.addSubview(slider)
                paramRowView.addSubview(valueLabel)
                paramRowView.addSubview(maxLabel)

                NSLayoutConstraint.activate([
                    minLabel.leadingAnchor.constraint(equalTo: paramRowView.leadingAnchor),
                    minLabel.centerYAnchor.constraint(equalTo: paramRowView.centerYAnchor),
                    minLabel.widthAnchor.constraint(equalToConstant: 40),

                    slider.leadingAnchor.constraint(equalTo: minLabel.trailingAnchor, constant: 8),
                    slider.centerYAnchor.constraint(equalTo: paramRowView.centerYAnchor),
                    slider.widthAnchor.constraint(equalToConstant: 120),

                    valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
                    valueLabel.centerYAnchor.constraint(equalTo: paramRowView.centerYAnchor),
                    valueLabel.widthAnchor.constraint(equalToConstant: 50),

                    maxLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),
                    maxLabel.centerYAnchor.constraint(equalTo: paramRowView.centerYAnchor),
                    maxLabel.trailingAnchor.constraint(equalTo: paramRowView.trailingAnchor),

                    paramRowView.heightAnchor.constraint(equalToConstant: 30)
                ])

                stackView.addArrangedSubview(paramRowView)
            }

            if parameterCount > 10 {
                let moreLabel = NSTextField(labelWithString: "... 还有 \(parameterCount - 10) 个参数")
                moreLabel.font = NSFont.systemFont(ofSize: 11)
                moreLabel.textColor = .secondaryLabelColor
                stackView.addArrangedSubview(moreLabel)
            }
        } else {
            let infoLabel = NSTextField(wrappingLabelWithString: "此效果器已加载并集成到音效链中。在实时播放和导出时都会生效。")
            infoLabel.lineBreakMode = .byWordWrapping
            stackView.addArrangedSubview(infoLabel)
        }

        // 占位符
        let emptyView = NSView()
        emptyView.heightAnchor.constraint(equalToConstant: 50).isActive = true
        stackView.addArrangedSubview(emptyView)

        // 设置 stackView 的自动布局
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.setHuggingPriority(.defaultHigh, for: .vertical)

        // 配置 scrollView
        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        viewController.view = scrollView

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
        ])

        return viewController
    }
}




