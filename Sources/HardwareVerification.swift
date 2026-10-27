import AppKit

// Exercise the real controller callbacks without putting the user's Mac to sleep.
final class ControlRecoveryVerification {
    private let controller = AppController()
    private var stage = 0
    private var sawDisconnected = false
    private var timeout: Timer?

    func run() {
        NSApp.setActivationPolicy(.accessory)
        controller.selectedMode = .automatic
        controller.allowsServiceInstallation = !CommandLine.arguments.contains("--require-installed-service")
        controller.onChange = { [weak self] in self?.changed() }
        timeout = Timer.scheduledTimer(withTimeInterval: 150, repeats: false) { [weak self] _ in
            self?.finish("恢复验证超时")
        }
        print("验证自动控速的休眠/唤醒回调，不会让电脑实际休眠。")
        fflush(stdout)
        controller.startMonitoring()
    }

    private func changed() {
        guard stage < 5 else { return }
        if let error = controller.errorMessage, !((stage == 2 || stage == 3) && controller.controlRequested) { finish(error); return }
        guard let snapshot = controller.snapshot else { return }
        if stage == 0 {
            stage = 1; controller.enable()
        } else if stage == 1 && controller.enabled {
            stage = 2
            controller.allowsServiceInstallation = false
            controller.prepareForSleep()
            do {
                let fresh = try SensorReader(smc: SMCConnection()).snapshot()
                guard controller.controlRequested, !controller.enabled,
                      fresh.fans.allSatisfy({ $0.mode == 0 }) else {
                    finish("暂停时未保留开启意愿或未释放硬件"); return
                }
            } catch { finish(String(describing: error)); return }
            print("暂停通过：保留开启意愿，硬件已释放。正在验证无需授权自动恢复。")
            fflush(stdout)
            controller.resumeAfterWake()
        } else if stage == 2 && controller.enabled {
            guard controller.controlRequested,
                  snapshot.fans.allSatisfy({ $0.mode == 1 }) || (controller.targets.isEmpty && snapshot.fans.allSatisfy({ $0.mode == 0 })) else {
                finish("唤醒后未重新接管"); return
            }
            stage = 3
            print("唤醒通过：自动恢复接管，无需重新授权。")
            fflush(stdout)
            controller.interruptSessionForVerification { [weak self] error in
                if let error { self?.finish(String(describing: error)) }
            }
        } else if stage == 3 {
            if !controller.enabled { sawDisconnected = true }
            guard sawDisconnected && controller.enabled else { return }
            guard controller.controlRequested else { finish("失联恢复丢失开启意愿"); return }
            stage = 4
            print("真实会话中断通过：旧会话正常退出，保留开关，确认释放后自动重连，无需授权。")
            fflush(stdout)
            controller.disable { [self] in
                controller.prepareForSleep()
                controller.resumeAfterWake()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                    guard stage == 4 else { return }
                    guard !controller.controlRequested, !controller.enabled, !controller.authorizing else {
                        finish("用户关闭后被意外重新开启"); return
                    }
                    print("关闭意愿通过：用户关闭后，唤醒不会擅自开启。")
                    finish(nil)
                }
            }
        }
    }

    private func finish(_ error: String?) {
        guard stage < 5 else { return }
        stage = 5; timeout?.invalidate()
        controller.disable {
            self.controller.shutdown()
            if let error { fputs("恢复验证失败：\(error)\n", stderr); exit(1) }
            print("恢复验证通过。"); fflush(stdout); exit(0)
        }
    }
}

// Explicit, short-lived diagnostic through the same authorization + IPC path as the UI.
// Always requests system mode on completion; never remembers an enabled control mode.
final class HardwareVerification {
    private let controller = AppController()
    private var startedControl = false
    private var finishing = false
    private var controlStartedAt: Date?
    private var timeout: Timer?
    private var lastPrint = Date.distantPast
    private var completedCycles = 0

    func run() {
        NSApp.setActivationPolicy(.accessory)
        controller.selectedMode = .manual
        controller.manualRPM = 5000
        controller.allowsServiceInstallation = !CommandLine.arguments.contains("--require-installed-service")
        print("短时硬件验证：两次开启约 5000 RPM，分别关闭并确认恢复系统控制。\(controller.allowsServiceInstallation ? "首次安装服务可能请求管理员授权。" : "本次禁止安装或授权，只能复用现有后台服务。")")
        fflush(stdout)
        controller.onChange = { [weak self] in self?.changed() }
        timeout = Timer.scheduledTimer(withTimeInterval: 150, repeats: false) { [weak self] _ in
            self?.finish(error: "等待授权或硬件验证超时")
        }
        controller.startMonitoring()
    }

    private func changed() {
        guard !finishing else { return }
        if let error = controller.errorMessage { finish(error: error); return }
        guard let snapshot = controller.snapshot else { return }
        if !startedControl {
            startedControl = true
            print("初始：\(summary(snapshot))")
            fflush(stdout)
            controller.enable()
            return
        }
        guard controller.enabled else { return }
        if controlStartedAt == nil { controlStartedAt = Date() }
        if Date().timeIntervalSince(lastPrint) > 1 {
            print("控制中：\(summary(snapshot))")
            fflush(stdout)
            lastPrint = Date()
        }
        let elapsed = Date().timeIntervalSince(controlStartedAt!)
        let following = snapshot.fans.allSatisfy {
            guard let expected = controller.targets[$0.index] else { return false }
            return $0.mode == 1 && abs($0.target - expected) < 100 && $0.actual >= expected - 500
        }
        if following && elapsed >= 3 { finish(error: nil) }
        else if elapsed > 25 { finish(error: "目标值已写入，但实际转速未在 25 秒内跟上") }
    }

    private func summary(_ snapshot: ThermalSnapshot) -> String {
        snapshot.fans.map { "F\($0.index) mode=\($0.mode), target=\(Int($0.target)), actual=\(Int($0.actual))" }.joined(separator: "; ")
    }

    private func finish(error: String?) {
        guard !finishing else { return }
        finishing = true
        controller.disable { [self] in
            do {
                let snapshot = try SensorReader(smc: SMCConnection()).snapshot()
                print("结束：\(summary(snapshot))")
                if !snapshot.fans.allSatisfy({ $0.mode == 0 }) {
                    fputs("验证后未能确认自动模式，请恢复 Auto。\n", stderr)
                    exit(2)
                }
            } catch { fputs("恢复后读取失败：\(error)\n", stderr); exit(2) }
            if let error { controller.shutdown(); fputs("验证失败：\(error)\n", stderr); exit(1) }
            completedCycles += 1
            if completedCycles < 2 {
                print("第一轮完成，再次开启，验证后台服务复用。")
                fflush(stdout)
                finishing = false; controlStartedAt = nil
                controller.enable()
                return
            }
            timeout?.invalidate(); controller.shutdown()
            print("真机验证通过：连续两次开启、实际升速、关闭恢复系统控制。")
            fflush(stdout)
            exit(0)
        }
    }
}
