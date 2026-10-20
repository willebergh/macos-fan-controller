import AppKit
import Combine

@main
struct FanControlApp {
    static func main() {
        if CommandLine.arguments.contains("--helper") {
            do {
                guard CommandLine.arguments.count == 3, let uid = UInt32(CommandLine.arguments[2]) else { throw FanError("Invalid helper arguments.") }
                try PrivilegedHelper.run(uid: uid)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        } else if CommandLine.arguments.contains("--test-control") {
            do { try ControlDiagnostic.run() }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        } else if CommandLine.arguments.contains("--probe") {
            do {
                let smc = try SMC()
                let snapshot = try smc.snapshot()
                for fan in snapshot.fans {
                    print("Fan \(fan.id + 1): \(Int(fan.rpm)) RPM; limits \(Int(fan.minimum))–\(Int(fan.maximum)); manual: \(fan.manual.map(String.init) ?? "unknown")")
                }
                for temp in snapshot.temperatures { print("\(temp.name) [\(temp.id)]: \(String(format: "%.1f", temp.celsius)) °C") }
                do {
                    let safety = try smc.safetyTemperatures()
                    print("Safety sensors: \(safety.count) validated; hottest \(String(format: "%.1f", safety.max()!)) °C")
                } catch { print("Manual control unavailable: \(error.localizedDescription)") }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        } else {
            let application = NSApplication.shared
            let delegate = FanControlApplicationDelegate()
            application.setActivationPolicy(.accessory)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }
}

@MainActor
private final class StatusReadoutView: NSView {
    var text = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let size = text.boundingRect(with: NSSize(width: bounds.width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin]).size
        // Lower the centered readout by two points, clamping to avoid clipping
        // on shorter menu bars. The underlying status button still handles clicks.
        let y = max(0, (bounds.height - size.height) / 2 - 2)
        text.draw(with: NSRect(x: 0, y: y, width: bounds.width, height: size.height),
                  options: [.usesLineFragmentOrigin])
    }
}

@MainActor
final class FanControlApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var observation: AnyCancellable?
    private var temperatureItems: [NSMenuItem] = []
    private var fanItems: [NSMenuItem] = []
    private let sensorSeparator = NSMenuItem.separator()
    private let readout = StatusReadoutView()
    private let requestedItem = NSMenuItem()
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let systemItem = NSMenuItem(title: "System default", action: #selector(restoreSystem), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit FanControl", action: #selector(quit), keyEquivalent: "q")
    private var errorItems: [NSMenuItem] = []
    private var displayedError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            readout.frame = button.bounds
            readout.autoresizingMask = [.width, .height]
            button.addSubview(readout)
        }
        menu.addItem(sensorSeparator)
        menu.addItem(requestedItem)

        // Only the slider needs a custom menu-item view; everything else is native.
        let sliderItem = NSMenuItem()
        let sliderView = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 34))
        slider.frame = NSRect(x: 20, y: 6, width: 250, height: 22)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changeSpeed(_:))
        slider.setAccessibilityLabel("Requested manual speed, percent of maximum RPM")
        sliderView.addSubview(slider)
        sliderItem.view = sliderView
        menu.addItem(sliderItem)
        systemItem.target = self
        menu.addItem(systemItem)
        menu.addItem(.separator())
        quitItem.target = self
        menu.addItem(quitItem)

        // objectWillChange fires before assignment. Defer rendering to read the new values.
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        update()
    }

    func menuWillOpen(_ menu: NSMenu) { update() }

    private func update() {
        guard statusItem != nil else { return }
        let snapshot = model.snapshot
        let cpuKeys: Set<String> = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0T"]
        let hottestCPU = snapshot.temperatures.filter {
            $0.celsius.isFinite && ($0.name.localizedCaseInsensitiveContains("CPU") || cpuKeys.contains($0.id))
        }.map(\.celsius).max()
        let temperature = hottestCPU.map { String(format: "%.1f°C", $0) } ?? "—°C"
        // On multi-fan machines the compact label shows the fastest measured fan.
        let actualRPM = snapshot.fans.map(\.rpm).filter { $0.isFinite && $0 >= 0 }.max()
        let rpm = actualRPM.map { String(format: "%.0frpm", $0) } ?? "—rpm"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 10.5
        paragraph.maximumLineHeight = 10.5
        let title = NSAttributedString(string: "\(temperature)\n\(rpm)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            statusItem.length = ceil(title.size().width) + 16
            readout.frame = button.bounds
            readout.text = title
            button.toolTip = model.error ?? "Hottest CPU: \(temperature); \(snapshot.fans.count > 1 ? "fastest fan" : "actual fan speed"): \(rpm)"
            button.setAccessibilityLabel(button.toolTip)
        }

        // Keep the slider and action items in place while the native menu is tracking.
        let gpuKeys: Set<String> = ["Tg0G", "Tg0H", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        let hottestGPU = snapshot.temperatures.filter {
            $0.celsius.isFinite && ($0.name.localizedCaseInsensitiveContains("GPU") || gpuKeys.contains($0.id))
        }.map(\.celsius).max()
        let temperatures = [("CPU", hottestCPU), ("GPU", hottestGPU)].compactMap { name, value in
            value.map { "\(name): \(String(format: "%.1f", $0)) °C" }
        }
        resizeRows(&temperatureItems, count: temperatures.count, before: sensorSeparator)
        for (item, title) in zip(temperatureItems, temperatures) { item.title = title }
        resizeRows(&fanItems, count: snapshot.fans.count, before: sensorSeparator)
        for (item, fan) in zip(fanItems, snapshot.fans) {
            let measured = fan.rpm.isFinite && fan.rpm >= 0
                ? fan.rpm.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))) : "—"
            let name = snapshot.fans.count == 1 ? "Fan" : "Fan\(fan.id + 1)"
            item.title = "\(name): \(measured) RPM"
        }
        let confirmedSystem = !snapshot.fans.isEmpty && snapshot.fans.allSatisfy { $0.manual == false }
        systemItem.state = confirmedSystem ? .on : .off
        systemItem.isEnabled = !model.busy
        quitItem.isEnabled = !model.busy
        requestedItem.title = "Manual: \(Int(model.percentage.rounded()))%" + (model.busy ? " · Applying…" : "")
        requestedItem.isEnabled = false
        slider.doubleValue = model.percentage
        slider.isEnabled = !model.busy && !snapshot.fans.isEmpty && snapshot.fans.allSatisfy(\.controllable)
        updateError()
    }

    private func resizeRows(_ items: inout [NSMenuItem], count: Int, before anchor: NSMenuItem) {
        guard items.count != count else { return }
        for item in items { menu.removeItem(item) }
        items = (0..<count).map { _ in
            let item = NSMenuItem()
            item.isEnabled = false
            menu.insertItem(item, at: menu.index(of: anchor))
            return item
        }
    }

    private func updateError() {
        guard displayedError != model.error else { return }
        displayedError = model.error
        for item in errorItems { menu.removeItem(item) }
        errorItems.removeAll()
        guard let error = model.error, !error.isEmpty else { return }
        // Wrap into disabled native rows rather than adding another custom view.
        var lines = ["Error:"]
        for word in error.split(whereSeparator: { $0.isWhitespace }) {
            if lines[lines.count - 1].count + word.count + 1 > 55 {
                lines.append(String(word))
            } else {
                lines[lines.count - 1] += " " + word
            }
        }
        for line in lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = error
            menu.insertItem(item, at: menu.index(of: quitItem))
            errorItems.append(item)
        }
    }

    @objc private func changeSpeed(_ sender: NSSlider) { model.sliderChanged(sender.doubleValue) }
    @objc private func restoreSystem() { model.systemDefault() }
    @objc private func quit() { model.systemDefault(quit: true) }
}
