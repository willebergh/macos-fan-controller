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
        } else if CommandLine.arguments.contains("--mcp") {
            do { try MCPServer.run() }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
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

    var powerText = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let columnWidth = ceil(text.size().width)
        let size = text.boundingRect(with: NSSize(width: columnWidth, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin]).size
        // Lower the centered readout by two points, clamping to avoid clipping
        // on shorter menu bars. The underlying status button still handles clicks.
        let y = max(0, (bounds.height - size.height) / 2 - 2)
        text.draw(with: NSRect(x: 8, y: y, width: columnWidth, height: size.height),
                  options: [.usesLineFragmentOrigin])
        let powerSize = powerText.size()
        powerText.draw(with: NSRect(x: 8 + columnWidth + 8,
                                   y: max(0, (bounds.height - powerSize.height) / 2 - 2),
                                   width: ceil(powerSize.width), height: powerSize.height),
                       options: [.usesLineFragmentOrigin])
    }
}

/// A bounded informational row: even unbroken helper errors must not resize the menu.
@MainActor
final class MenuErrorView: NSView {
    static let width: CGFloat = 290

    init(error: String) {
        let label = NSTextField(wrappingLabelWithString: "Error: \(error)")
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.toolTip = error
        label.setAccessibilityLabel("Error: \(error)")

        let textWidth = Self.width - 40
        let lineHeight = NSLayoutManager().defaultLineHeight(for: label.font!)
        let textHeight = ceil(label.attributedStringValue.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let height = min(max(textHeight, lineHeight), ceil(lineHeight * 4))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height + 12))
        label.frame = NSRect(x: 20, y: 6, width: textWidth, height: height)
        addSubview(label)
        toolTip = error
    }

    required init?(coder: NSCoder) { nil }
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

        // Keep interactive actions native; the slider and bounded error text use custom views.
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
        let power = snapshot.systemPowerWatts.map { String(format: "%.1fW", $0) } ?? "—W"
        let cpu = model.cpuUtilization.map { String(format: "%.0f%%", $0) } ?? "—%"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 10.5
        paragraph.maximumLineHeight = 10.5
        let powerTitle = NSAttributedString(string: "\(cpu)\n\(power)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        let title = NSAttributedString(string: "\(temperature)\n\(rpm)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            statusItem.length = ceil(title.size().width) + ceil(powerTitle.size().width) + 24
            readout.frame = button.bounds
            readout.text = title
            readout.powerText = powerTitle
            button.toolTip = model.error ?? "Hottest CPU: \(temperature); \(snapshot.fans.count > 1 ? "fastest fan" : "actual fan speed"): \(rpm); CPU utilization: \(cpu); system power: \(power)"
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
        let item = NSMenuItem()
        item.view = MenuErrorView(error: error)
        item.isEnabled = false
        item.toolTip = error
        menu.insertItem(item, at: menu.index(of: quitItem))
        errorItems.append(item)
    }

    @objc private func changeSpeed(_ sender: NSSlider) { model.sliderChanged(sender.doubleValue) }
    @objc private func restoreSystem() { model.systemDefault() }
    @objc private func quit() { model.systemDefault(quit: true) }
}
