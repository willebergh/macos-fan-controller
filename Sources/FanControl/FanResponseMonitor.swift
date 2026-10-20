import Foundation

struct FanResponseMonitor {
    let startedAt: TimeInterval
    let initial: [FanReading]
    let percent: Double

    enum Result: Equatable { case waiting, reached, failed(String) }

    func evaluate(_ current: [FanReading], now: TimeInterval) -> Result {
        let elapsed = now - startedAt
        var allReached = true
        for start in initial {
            guard let fan = current.first(where: { $0.id == start.id }) else {
                return .failed("Fan \(start.id + 1) stopped reporting RPM.")
            }
            let target = start.target(percent: percent)
            let tolerance = max(150, target * 0.1)
            if elapsed >= 2, fan.manual != true {
                return .failed("Fan \(start.id + 1) did not stay in manual mode.")
            }
            if abs(fan.rpm - target) > tolerance {
                allReached = false
                // Report a clearly ignored request sooner than a slow settling fan.
                if elapsed >= 10, abs(target - start.rpm) >= 600,
                   abs(fan.rpm - start.rpm) < 150 {
                    return .failed("Fan \(start.id + 1) did not respond: requested \(Int(target)) RPM, measured \(Int(fan.rpm)) RPM.")
                }
                if elapsed >= 30 {
                    return .failed("Fan \(start.id + 1) failed to reach \(Int(target)) RPM (measured \(Int(fan.rpm)) RPM).")
                }
            }
        }
        return allReached && !initial.isEmpty ? .reached : .waiting
    }
}
