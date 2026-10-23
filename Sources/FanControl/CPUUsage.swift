import Darwin

/// System-wide busy time between samples, normalized to 0–100% across all cores.
final class CPUUsageSampler {
    struct Ticks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

    private var previous: Ticks?
    private let read: () -> Ticks?

    init(read: @escaping () -> Ticks? = CPUUsageSampler.readTicks) {
        self.read = read
    }

    func sample() -> Double? {
        guard let current = read() else {
            previous = nil
            return nil
        }
        defer { previous = current }
        guard let previous else { return nil }
        let busy = UInt64(current.user &- previous.user)
            + UInt64(current.system &- previous.system)
            + UInt64(current.nice &- previous.nice)
        let total = busy + UInt64(current.idle &- previous.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    static func readTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Ticks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                     idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}
