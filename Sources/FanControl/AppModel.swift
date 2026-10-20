import AppKit
import SwiftUI
import SMCBridge
import CryptoKit
import Security

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var percentage = 50.0
    @Published var isManual = false
    @Published var busy = false
    @Published var error: String?
    @Published var loading = true
    @Published var verifying = false
    private var responseMonitor: FanResponseMonitor?
    private var committedPercentage = 50.0

    private let queue = DispatchQueue(label: "personal-fan.hardware")
    private let hardware = HardwareController()
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var desiredManual = false
    private var reading = false
    private var resetting = false
    private var manualActivity: NSObjectProtocol?

    private func keepManualActivity() {
        if manualActivity == nil {
            manualActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Maintain the manual fan-control heartbeat")
        }
    }

    private func endManualActivity() {
        if let activity = manualActivity {
            ProcessInfo.processInfo.endActivity(activity)
            manualActivity = nil
        }
    }

    init() {
        refresh()
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(timer!, forMode: .eventTracking)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDefault() }
        }
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        let keepManual = desiredManual && isManual && !resetting
        let percent = committedPercentage
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.hardware.smc == nil { self.hardware.smc = try SMC() }
                var controlFailure: String?
                if keepManual {
                    do { _ = try PrivilegedHelper.request("heartbeat \(self.hardware.lease) \(percent)") }
                    catch { controlFailure = error.localizedDescription }
                } else {
                    // Renew an existing authorization session even after a thermal
                    // reset or a switch to system mode. Never launch/authorize here.
                    // Ping does NOT renew the manual watchdog's lastManual timestamp.
                    _ = try? PrivilegedHelper.request("ping")
                }
                // Keep measured RPM/temperature live even when a control request fails.
                let value = try self.hardware.smc!.snapshot()
                let failure = controlFailure
                Task { @MainActor in
                    self.snapshot = value
                    self.loading = false
                    self.reading = false
                    if let failure {
                        self.systemDefault(reason: "Manual control failed: \(failure)")
                    } else if self.desiredManual, let monitor = self.responseMonitor {
                        switch monitor.evaluate(value.fans, now: ProcessInfo.processInfo.systemUptime) {
                        case .waiting: self.verifying = true
                        case .reached: self.verifying = false
                        case .failed(let reason): self.systemDefault(reason: reason)
                        }
                    }
                    if !self.desiredManual, self.error == nil, value.fans.contains(where: { $0.manual == true }) {
                        self.error = "The SMC reports manual mode. Choose System default to restore it."
                    }
                }
            } catch {
                Task { @MainActor in
                    self.error = error.localizedDescription
                    self.loading = false
                    self.reading = false
                    if keepManual {
                        self.desiredManual = false
                        self.isManual = false
                        self.endManualActivity()
                        self.error = "Manual connection lost. The helper will attempt system control within 10 seconds. \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func sliderChanged(_ value: Double) {
        percentage = value.rounded()
        responseMonitor = nil
        verifying = false
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.applyManual() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func applyManual() {
        guard !busy, !snapshot.fans.isEmpty else { return }
        busy = true
        desiredManual = true
        keepManualActivity()
        error = nil
        let percent = percentage
        let initialFans = snapshot.fans
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.hardware.authorize()
                _ = try PrivilegedHelper.request("manual \(self.hardware.lease) \(percent)")
                Task { @MainActor in
                    self.isManual = true; self.busy = false
                    self.committedPercentage = percent
                    self.verifying = true
                    self.responseMonitor = FanResponseMonitor(startedAt: ProcessInfo.processInfo.systemUptime, initial: initialFans, percent: percent)
                    if !self.desiredManual { self.systemDefault() }
                    else { self.refresh() }
                }
            } catch {
                Task { @MainActor in
                    self.error = "Not applied: \(error.localizedDescription)"
                    self.desiredManual = false; self.isManual = false; self.busy = false
                    self.verifying = false; self.responseMonitor = nil
                    self.endManualActivity()
                    self.refresh()
                }
            }
        }
    }

    func systemDefault(quit: Bool = false, reason: String? = nil) {
        pending?.cancel()
        desiredManual = false
        endManualActivity()
        verifying = false
        responseMonitor = nil
        guard !resetting else { return }
        if busy {
            if quit { error = "Finish or cancel authorization before quitting." }
            return
        }
        resetting = true
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let alreadySystem = (try? self.hardware.smc?.fans().allSatisfy { $0.manual == false }) == true
                let helper = (try? PrivilegedHelper.request("ping")) != nil
                if helper {
                    _ = try PrivilegedHelper.request(quit ? "quit" : "system")
                } else if !alreadySystem {
                    try self.hardware.authorize()
                    _ = try PrivilegedHelper.request(quit ? "quit" : "system")
                }
                Task { @MainActor in
                    self.isManual = false; self.error = reason.map { $0 + " System control restored." }; self.busy = false; self.resetting = false
                    self.refresh()
                    if quit { NSApp.terminate(nil) }
                }
            } catch {
                Task { @MainActor in
                    self.error = "Could not confirm system control: \(error.localizedDescription)"
                    self.busy = false; self.resetting = false
                }
            }
        }
    }
}

// All mutable hardware state is confined to AppModel's serial hardware queue.
final class HardwareController: @unchecked Sendable {
    var smc: SMC?
    let lease = UUID().uuidString

    func authorize() throws {
        if (try? PrivilegedHelper.request("session 2")) != nil { return }
        // Replace pre-session-lifetime helpers once, rather than silently reusing
        // the old short-idle implementation after an app update.
        if (try? PrivilegedHelper.request("ping")) != nil {
            _ = try PrivilegedHelper.request("quit")
        }
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        // Stage a private root-owned copy and verify its bytes against the running
        // app's digest. Never execute a replaceable user-writable path as root.
        var runningCode: SecCode?
        var signingInfo: CFDictionary?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode,
              SecCodeCopySigningInformation(unsafeBitCast(runningCode, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any], let identity = info[kSecCodeInfoUnique as String] as? Data else {
            throw FanError("Cannot verify this app's code identity. Rebuild and run the signed app bundle.")
        }
        let cdhash = identity.map { String(format: "%02x", $0) }.joined()
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable)))
            .map { String(format: "%02x", $0) }.joined()
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw FanError("Run the built FanControl.app to authorize fan control.") }
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents").path
        let command = """
        set -eu
        umask 077
        work=$(/usr/bin/mktemp -d /private/var/root/fancontrol.XXXXXXXX)
        trap '/bin/rm -rf "$work"' EXIT
        app="$work/FanControl.app"
        /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/_CodeSignature"
        /bin/cp \(shellQuote(executable)) "$app/Contents/MacOS/FanControl"
        /bin/cp \(shellQuote(contents + "/Info.plist")) "$app/Contents/Info.plist"
        /bin/cp \(shellQuote(contents + "/_CodeSignature/CodeResources")) "$app/Contents/_CodeSignature/CodeResources"
        /bin/chmod 500 "$app/Contents/MacOS/FanControl"
        actual=$(/usr/bin/shasum -a 256 "$app/Contents/MacOS/FanControl" | /usr/bin/cut -d ' ' -f 1)
        [ "$actual" = \(shellQuote(digest)) ] || exit 1
        /usr/bin/codesign --verify --strict "$app"
        identity=$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2}')
        [ "$identity" = \(shellQuote(cdhash)) ] || exit 1
        (trap '/bin/rm -rf "$work"' EXIT; "$app/Contents/MacOS/FanControl" --helper \(getuid())) > /dev/null 2>&1 < /dev/null &
        trap - EXIT
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptQuote(command)) with administrator privileges with prompt \(appleScriptQuote("FanControl needs permission to adjust fan speed. System control is restored when manual control ends."))"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 75) == .success else {
            process.terminate()
            throw FanError("Authorization timed out. Move the slider to try again.")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FanError(message.contains("-128") ? "Authorization cancelled. Fan settings were not changed." : "Authorization failed. \(message)")
        }
        // Short, bounded startup retry on the hardware queue; never on the main thread.
        for _ in 0..<20 {
            if (try? PrivilegedHelper.request("ping")) != nil { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw FanError("The helper could not start. Check for another FanControl instance or a stale /var/run/personal-fan-\(getuid()).sock.")
    }

}
