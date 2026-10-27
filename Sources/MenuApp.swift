import AppKit

enum CompactStatusImage {
    static let size = NSSize(width: 52, height: 22)
    static let itemWidth: CGFloat = 60

    static func make(temperature: String, rpm: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let fan = NSImage(systemSymbolName: "fanblades", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            fan?.draw(in: NSRect(x: 0, y: 3, width: 16, height: 16))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
            (temperature as NSString).draw(in: NSRect(x: 19, y: 11, width: 33, height: 11), withAttributes: attributes)
            (rpm as NSString).draw(in: NSRect(x: 19, y: 0, width: 33, height: 11), withAttributes: attributes)
            return true
        }
        // AppKit supplies the appropriate color for light/dark menus and selection.
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private let controller = AppController()
    private var pendingManualRPM: Double?
    private var pendingControlMode: FanMode?

    init(manualRPM: Double? = nil, automatic: Bool = false) {
        pendingManualRPM = manualRPM
        pendingControlMode = manualRPM != nil ? .manual : (automatic ? .automatic : nil)
        super.init()
    }
    private var statusItem: NSStatusItem!
    private let toggle = NSSwitch()
    private let modePicker = NSSegmentedControl(labels: ["自动调节", "手动转速"], trackingMode: .selectOne, target: nil, action: nil)
    private let slider = NSSlider(value: 3000, minValue: 1200, maxValue: 7200, target: nil, action: nil)
    private let manualField = NSTextField(string: "3000")
    private let stateLabel = NSTextField(labelWithString: "系统自动控制")
    private let detailLabel = NSTextField(wrappingLabelWithString: "正在读取传感器…")
    private let primary = NSTextField(labelWithString: "—")
    private let secondary = NSTextField(labelWithString: "—")
    private let battery = NSTextField(labelWithString: "—")
    private let cpu = NSTextField(labelWithString: "—")
    private let fanActual = NSTextField(labelWithString: "—")
    private let fanTarget = NSTextField(labelWithString: "—")
    private let power = NSTextField(labelWithString: "—")
    private let time = NSTextField(labelWithString: "每 2 秒更新")
    private let manualHint = NSTextField(wrappingLabelWithString: "手动模式也保留 CPU 过热保护。")
    private let version = "1.6"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: CompactStatusImage.itemWidth)
        if let button = statusItem.button {
            button.image = CompactStatusImage.make(temperature: "—°", rpm: "—")
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityLabel("SmartFan 温度与风扇")
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let panel = NSMenuItem()
        panel.view = makePanel()
        menu.addItem(panel)
        menu.addItem(.separator())
        let feelings = NSMenuItem(title: "记录掌托体感", action: nil, keyEquivalent: "")
        let feelingsMenu = NSMenu()
        for (index, label) in ["冰凉", "舒适", "温热（希望避免）", "比较热（介入偏晚）"].enumerated() {
            let item = NSMenuItem(title: label, action: #selector(record(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; feelingsMenu.addItem(item)
        }
        feelings.submenu = feelingsMenu; menu.addItem(feelings)
        addItem("查看温度记录…", #selector(openRecords), to: menu)
        addItem("关于自动策略…", #selector(showPolicy), to: menu)
        menu.addItem(.separator())
        addItem("退出 SmartFan", #selector(quit), to: menu, key: "q")
        statusItem.menu = menu
        controller.onChange = { [weak self] in
            guard let self else { return }
            self.refresh()
            // An explicit launch request uses the same checks and authorization as the menu.
            if let mode = self.pendingControlMode, self.controller.snapshot?.controlReady == true {
                self.pendingControlMode = nil
                if let rpm = self.pendingManualRPM { self.controller.updateManual(rpm) }
                self.pendingManualRPM = nil
                self.controller.updateMode(mode)
                self.controller.enable()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        controller.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }

    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }
    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    private func row(_ title: String, value: NSView) -> NSStackView {
        let stack = NSStackView(views: [label(title), NSView(), value])
        stack.orientation = .horizontal; stack.alignment = .centerY
        stack.heightAnchor.constraint(equalToConstant: 24).isActive = true
        value.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }
    private func divider() -> NSBox {
        let box = NSBox(); box.boxType = .separator
        return box
    }
    private func makePanel() -> NSView {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 346, height: 468))
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12)
        ])
        let header = NSStackView(views: [label("SmartFan", size: 16, weight: .semibold), NSView(), stateLabel])
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        header.orientation = .horizontal
        stack.addArrangedSubview(header)
        toggle.target = self; toggle.action = #selector(toggleChanged)
        toggle.setAccessibilityLabel("SmartFan 控制开关")
        stack.addArrangedSubview(row("风扇控制", value: toggle))
        modePicker.selectedSegment = 0; modePicker.target = self; modePicker.action = #selector(modeChanged)
        modePicker.segmentDistribution = .fillEqually
        stack.addArrangedSubview(modePicker)
        stack.addArrangedSubview(divider())
        let title = label("温度指标", size: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor; stack.addArrangedSubview(title)
        for field in [primary, secondary, battery, cpu, fanActual, fanTarget] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        stack.addArrangedSubview(row("体感参考 · Ts1P", value: primary))
        stack.addArrangedSubview(row("辅助参考 · Ts0P", value: secondary))
        stack.addArrangedSubview(row("电池 · 最高", value: battery))
        stack.addArrangedSubview(row("CPU · 最高", value: cpu))
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(row("风扇实际", value: fanActual))
        stack.addArrangedSubview(row("目标转速", value: fanTarget))
        slider.target = self; slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.isEnabled = false
        slider.setAccessibilityLabel("手动风扇转速")
        manualField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        manualField.alignment = .right; manualField.delegate = self
        manualField.target = self; manualField.action = #selector(manualEntered)
        manualField.isEnabled = false
        manualField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        manualField.setAccessibilityLabel("手动转速 RPM")
        let manualRow = NSStackView(views: [slider, manualField, label("RPM", size: 11)])
        manualRow.orientation = .horizontal; stack.addArrangedSubview(manualRow)
        manualHint.font = .systemFont(ofSize: 10); manualHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(manualHint)
        stack.addArrangedSubview(divider())
        let footer = NSStackView(views: [power, NSView(), time])
        footer.orientation = .horizontal
        power.font = .systemFont(ofSize: 10); power.textColor = .secondaryLabelColor
        time.font = .systemFont(ofSize: 10); time.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footer)
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.maximumNumberOfLines = 3
        detailLabel.heightAnchor.constraint(equalToConstant: 42).isActive = true
        stack.addArrangedSubview(detailLabel)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        panel.layoutSubtreeIfNeeded()
        panel.setFrameSize(NSSize(width: 346, height: stack.fittingSize.height + 24))
        return panel
    }

    private func refresh() {
        let active = controller.controlRequested || controller.enabled || controller.authorizing
        toggle.state = active ? .on : .off
        toggle.isEnabled = !controller.stopping
        modePicker.selectedSegment = controller.selectedMode == .manual ? 1 : 0
        modePicker.isEnabled = !controller.authorizing && !controller.stopping
        let manual = controller.selectedMode == .manual
        let canAdjustManual = manual && controller.enabled && !controller.authorizing && !controller.stopping
        refreshSpeedDisplay(manual: manual, canAdjust: canAdjustManual, fans: controller.snapshot?.fans ?? [])
        stateLabel.stringValue = controller.authorizing ? (controller.installing ? "等待安装授权" : "正在连接") : (controller.stopping ? "正在关闭" :
            (controller.enabled ? (controller.selectedMode == .manual ? "手动控制" :
                (controller.targets.isEmpty ? "低温待机" : "自动控速")) :
                (controller.reconnecting ? "等待恢复控速" : "系统接管")))
        stateLabel.textColor = controller.enabled ? .controlAccentColor : .secondaryLabelColor
        detailLabel.stringValue = controller.errorMessage ?? controller.message
        detailLabel.textColor = controller.errorMessage == nil ? .secondaryLabelColor : .systemOrange
        guard let snapshot = controller.snapshot else { return }
        if !active && !controller.stopping && snapshot.fans.contains(where: { $0.mode != 0 }) {
            stateLabel.stringValue = "外部控制"
        }
        func temperature(_ value: Double?) -> String { value.map { String(format: "%.1f °C", $0) } ?? "不可用" }
        primary.stringValue = temperature(snapshot.primary); secondary.stringValue = temperature(snapshot.secondary)
        battery.stringValue = temperature(snapshot.battery); cpu.stringValue = temperature(snapshot.cpu)
        fanActual.stringValue = snapshot.fans.map { String(Int($0.actual.rounded())) }.joined(separator: " / ") + " RPM"
        fanTarget.stringValue = snapshot.fans.map { String(Int((controller.targets[$0.index] ?? $0.target).rounded())) }.joined(separator: " / ") + " RPM"
        power.stringValue = snapshot.powerSource == "AC Power" ? (snapshot.isCharging == true ? "接电 · 充电中" : "接电 · 未充电") : "电池供电"
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        let stale = Date().timeIntervalSince(snapshot.timestamp) > 6
        time.stringValue = (stale ? "数据已过期 · " : "更新 ") + formatter.string(from: snapshot.timestamp)
        let degree = snapshot.primary.map { String(Int($0.rounded())) + "°" } ?? "—°"
        let rpm = snapshot.fans.first.map { String(Int($0.actual.rounded())) } ?? "—"
        statusItem.button?.image = CompactStatusImage.make(temperature: stale ? "—°" : degree, rpm: stale ? "—" : rpm)
        statusItem.button?.setAccessibilityLabel(stale ? "SmartFan，温度数据已过期" : "SmartFan，Ts1P \(degree)，风扇 \(rpm) RPM")
        statusItem.button?.toolTip = "SmartFan · Ts1P \(temperature(snapshot.primary)) · \(stateLabel.stringValue)"
        if controller.authorizing {
            manualHint.stringValue = controller.installing ? "首次安装或更新服务需要授权，转速尚未应用。" : "正在连接后台服务，转速尚未应用。"
        } else if controller.enabled && !manual && controller.targets.isEmpty {
            manualHint.stringValue = "持续监测中；硬件自行决定停转，升温自动接管。"
        } else if !manual {
            manualHint.stringValue = "滑块实时显示实际转速，每 2 秒更新。"
        } else if !controller.enabled {
            manualHint.stringValue = "开启「风扇控制」即可应用；首次安装服务需要授权。"
        } else {
            manualHint.stringValue = manual ? "手动模式也保留 CPU 过热保护。" : "自动曲线会提前升速，并延迟缓慢降速。"
        }
    }

    private func refreshSpeedDisplay(manual: Bool, canAdjust: Bool, fans: [FanReading]) {
        slider.isEnabled = canAdjust
        manualField.isEnabled = manual ? canAdjust : true
        manualField.isEditable = canAdjust
        manualField.isSelectable = !manual
        manualField.isBezeled = manual
        manualField.drawsBackground = manual
        if manual {
            slider.minValue = fans.map(\.minimum).max() ?? 1200
            slider.maxValue = fans.map(\.maximum).min() ?? 7200
            slider.doubleValue = controller.manualRPM
            if manualField.currentEditor() == nil {
                manualField.stringValue = String(Int(controller.manualRPM.rounded()))
            }
        } else {
            // This is a live readout, including when macOS is controlling the fan.
            // Keep the manual setpoint intact so switching tabs restores it.
            slider.minValue = 0
            slider.maxValue = fans.first?.maximum ?? 7200
            slider.doubleValue = fans.first?.actual ?? 0
            manualField.stringValue = fans.first.map { String(Int($0.actual.rounded())) } ?? "—"
        }
        let description = manual ? "手动转速 RPM" : "风扇实际转速 RPM（每 2 秒更新）"
        slider.setAccessibilityLabel(description)
        manualField.setAccessibilityLabel(description)
        slider.toolTip = manual ? "设置手动转速" : "实际转速，只读显示"
    }

    @objc private func toggleChanged() { toggle.state == .on ? controller.enable() : controller.disable() }
    @objc private func modeChanged() {
        if manualField.currentEditor() != nil { manualField.window?.makeFirstResponder(nil) }
        controller.updateMode(modePicker.selectedSegment == 1 ? .manual : .automatic)
    }
    @objc private func sliderChanged() { controller.updateManual((slider.doubleValue / 100).rounded() * 100) }
    @objc private func manualEntered() { applyManualField() }
    func controlTextDidEndEditing(_ obj: Notification) { applyManualField() }
    private func applyManualField() {
        guard controller.selectedMode == .manual, controller.enabled,
              !controller.authorizing, !controller.stopping else { return }
        if let value = Double(manualField.stringValue), value.isFinite { controller.updateManual(value); controller.poll() }
        else { NSSound.beep(); manualField.stringValue = String(Int(controller.manualRPM)) }
    }
    @objc private func record(_ item: NSMenuItem) { controller.recordFeeling(["cold", "comfortable", "warm", "hot"][item.tag]) }
    @objc private func openRecords() {
        try? FileManager.default.createDirectory(at: controller.observations.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(controller.observations.directory)
    }
    @objc private func showPolicy() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SmartFan \(version) · 提前保持舒适"
        alert.informativeText = "自动模式取体感参考 Ts1P、电池温度与 CPU 保护曲线中的较高转速。\n\n舒适区低速维持：Ts1P ≤ 30°C、电池 ≤ 33.8°C 时降低转速，仍保持自动接管。Ts1P 30.5 / 31°C 对应约 2600 / 4000 RPM；电池 34.2 / 34.8°C 对应约 2600 / 5000 RPM。升温趋势可能提前提高转速。\n\n冰凉时自动待机：参考温度持续偏低 20 秒后暂用硬件自动模式，允许自行停转；开关与监测保持开启。温度上升或 CPU ≥ 75°C 时自动重新接管。\n\nCPU ≥ 92°C 或严重热压力时使用最高转速，手动模式也保留保护。休眠时暂时释放，唤醒后自动恢复原来的控制；短暂断连会自动重连，连续失败或硬件故障会明确报错。用户关闭或退出时释放控制。\n\n这些曲线仍需按你的体感校准，传感器位置尚未核实。每 30 秒保存温度记录，并记录控制暂停与恢复的原因。"
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }
    @objc private func willSleep() { controller.prepareForSleep() }
    @objc private func didWake() { controller.resumeAfterWake() }
    @objc private func quit() { NSApp.terminate(nil) }

    // Render the app's own view for layout verification, without interacting with the desktop.
    func renderPreview(to path: String) throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        let panel = makePanel()
        primary.stringValue = "30.0 °C"; secondary.stringValue = "33.0 °C"
        battery.stringValue = "34.0 °C"; cpu.stringValue = "68.7 °C"
        fanActual.stringValue = "3600 RPM"; fanTarget.stringValue = "3600 RPM"
        power.stringValue = "接电 · 未充电"; time.stringValue = "更新 11:30:00"
        stateLabel.stringValue = "自动控速"; toggle.state = .on
        detailLabel.stringValue = "提前散热 · 体感与电池温度"
        refreshSpeedDisplay(manual: false, canAdjust: false,
                            fans: [FanReading(index: 0, minimum: 1200, maximum: 7200, actual: 3600, target: 3600, mode: 1)])
        manualHint.stringValue = "滑块实时显示实际转速，每 2 秒更新。"
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.layoutSubtreeIfNeeded()
        guard let image = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { throw SamplingError("无法渲染菜单预览") }
        panel.cacheDisplay(in: panel.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw SamplingError("无法编码菜单预览") }
        try data.write(to: URL(fileURLWithPath: path))
        print("Rendered menu panel: \(Int(panel.frame.width)) × \(Int(panel.frame.height))")
    }

    func renderStatusPreview(to path: String) throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        let preview = NSImage(size: NSSize(width: 220, height: 32), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 220, height: 32).fill()
            for (index, values) in [("34°", "1200"), ("30°", "7199"), ("—°", "—")].enumerated() {
                CompactStatusImage.make(temperature: values.0, rpm: values.1)
                    .draw(in: NSRect(x: 8 + index * 72, y: 5, width: 52, height: 22))
            }
            return true
        }
        guard let data = preview.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SamplingError("无法渲染菜单栏预览")
        }
        try png.write(to: URL(fileURLWithPath: path))
        print("Rendered compact status images; item width: \(Int(CompactStatusImage.itemWidth)) pt")
    }
}

@main
enum MenuApplication {
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--verify-control-recovery") {
            let verification = ControlRecoveryVerification()
            verification.run()
            application.run()
            withExtendedLifetime(verification) {}
            return
        }
        if CommandLine.arguments.contains("--verify-fan-control") {
            let verification = HardwareVerification()
            verification.run()
            application.run()
            withExtendedLifetime(verification) {}
            return
        }
        var manualRPM: Double?
        if let index = CommandLine.arguments.firstIndex(of: "--manual-rpm") {
            guard CommandLine.arguments.count > index + 1,
                  let value = Double(CommandLine.arguments[index + 1]), value.isFinite,
                  value >= 1000, value <= 15000 else {
                fputs("--manual-rpm 需要 1000–15000 范围内的数值；实际设置还会限制在硬件允许范围。\n", stderr)
                exit(1)
            }
            manualRPM = value
        }
        let delegate = AppDelegate(manualRPM: manualRPM, automatic: CommandLine.arguments.contains("--automatic"))
        if let index = CommandLine.arguments.firstIndex(of: "--render-status-preview"), CommandLine.arguments.count > index + 1 {
            do { try delegate.renderStatusPreview(to: CommandLine.arguments[index + 1]) }
            catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            do { try delegate.renderPreview(to: CommandLine.arguments[index + 1]) }
            catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
