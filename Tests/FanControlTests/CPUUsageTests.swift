import XCTest
@testable import FanControl

final class CPUUsageTests: XCTestCase {
    func testIntervalUsageIncludesSystemAndNice() {
        var ticks = CPUUsageSampler.Ticks(user: 10, system: 20, idle: 30, nice: 0)
        let sampler = CPUUsageSampler(read: { ticks })
        XCTAssertNil(sampler.sample())
        ticks = .init(user: 30, system: 30, idle: 90, nice: 10)
        XCTAssertEqual(sampler.sample()!, 40, accuracy: 0.001)
        XCTAssertNil(sampler.sample())
        ticks = .init(user: 30, system: 30, idle: 100, nice: 10)
        XCTAssertEqual(sampler.sample(), 0)
        ticks = .init(user: 40, system: 30, idle: 100, nice: 10)
        XCTAssertEqual(sampler.sample(), 100)
    }

    func testFailureResetsBaseline() {
        var ticks: CPUUsageSampler.Ticks? = .init(user: 0, system: 0, idle: 0, nice: 0)
        let sampler = CPUUsageSampler(read: { ticks })
        XCTAssertNil(sampler.sample())
        ticks = nil
        XCTAssertNil(sampler.sample())
        ticks = .init(user: 10, system: 0, idle: 10, nice: 0)
        XCTAssertNil(sampler.sample())
    }

    func testCounterWrap() {
        var ticks = CPUUsageSampler.Ticks(user: .max - 4, system: 0, idle: 0, nice: 0)
        let sampler = CPUUsageSampler(read: { ticks })
        XCTAssertNil(sampler.sample())
        ticks = .init(user: 5, system: 0, idle: 10, nice: 0)
        XCTAssertEqual(sampler.sample(), 50)
    }

    func testLiveTicksAvailable() {
        XCTAssertNotNil(CPUUsageSampler.readTicks())
    }
}
