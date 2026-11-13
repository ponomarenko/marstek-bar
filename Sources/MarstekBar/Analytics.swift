import Foundation

/// Heuristics over the 24-hour history. All of them are estimates, not measurements.
enum Analytics {
    /// Below this many watts the battery counts as idle (same band as `Snapshot`).
    static let idleBand: Double = 20
    static let sustainedWatts: Double = 300
    static let sustainedFor: TimeInterval = 2 * 3600

    private static func loads(_ history: [HistoryPoint]) -> [Double] {
        history.compactMap(\.power).filter { $0 > idleBand }
    }

    /// Mean output power over the moments the battery was discharging.
    static func averageLoad(_ history: [HistoryPoint]) -> Double? {
        let values = loads(history)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Share of the capacity discharged over the history window (1.0 = one full cycle).
    static func utilization(_ history: [HistoryPoint]) -> Double? {
        guard history.count > 1 else { return nil }
        let drops = zip(history, history.dropFirst()).map { max(0, $0.soc - $1.soc) }
        return Double(drops.reduce(0, +)) / 100
    }

    /// Full capacity extrapolated from the remaining energy, relative to the rated one.
    /// shortcut: trusts the BMS numbers and an integer SoC, so it is skipped at a low charge
    /// and rejected when implausible; upgrade if the API ever exposes a cycle count or SoH.
    static func health(soc: Int, remainingWh: Double?, ratedWh: Double?) -> Double? {
        guard soc >= 30, let remainingWh, let ratedWh, ratedWh > 0 else { return nil }
        let value = remainingWh / (Double(soc) / 100) / ratedWh
        return (0.5...1.05).contains(value) ? min(value, 1) : nil
    }

    /// True when every poll of the last `sustainedFor` shows a load above `sustainedWatts`.
    static func isSustained(_ history: [HistoryPoint], now: Date) -> Bool {
        let recent = history.filter { now.timeIntervalSince($0.date) <= sustainedFor }
        // Polls are a minute apart; demand that most of the window is covered.
        return recent.count >= Int(sustainedFor / 60 * 0.8)
            && recent.allSatisfy { ($0.power ?? 0) >= sustainedWatts }
    }

    #if DEBUG
    static func selfCheck() {
        let now = Date()
        func points(_ values: [(soc: Int, power: Double?)], step: TimeInterval = 60) -> [HistoryPoint] {
            values.enumerated().map { index, value in
                HistoryPoint(date: now.addingTimeInterval(-step * Double(values.count - 1 - index)),
                             soc: value.soc, power: value.power)
            }
        }
        let mixed = points([(80, 400), (78, 200), (78, -500), (90, 5), (85, nil)])
        assert(BatteryModel.signed16(64332) == -1204 && BatteryModel.signed16(800) == 800)
        assert(BatteryModel.format(watts: 1194).hasPrefix("1.19") && BatteryModel.format(watts: -999.6).hasPrefix("-1.00"))
        assert(BatteryModel.format(watts: 999.4).hasPrefix("999"))
        assert(averageLoad(mixed) == 300)
        assert(utilization(mixed) == 0.07) // drops 2 + 5, the recharge is ignored
        assert(averageLoad(points([(50, nil)])) == nil)
        assert(health(soc: 50, remainingWh: 1200, ratedWh: 2560) == 1200 / 0.5 / 2560)
        assert(health(soc: 10, remainingWh: 250, ratedWh: 2560) == nil)
        assert(health(soc: 50, remainingWh: 120, ratedWh: 2560) == nil) // wrong units
        let busy = points(Array(repeating: (50, 350), count: 120))
        assert(isSustained(busy, now: now))
        assert(!isSustained(Array(busy.suffix(30)), now: now))
        assert(!isSustained(busy + points([(50, 100)]), now: now))
    }
    #endif
}
