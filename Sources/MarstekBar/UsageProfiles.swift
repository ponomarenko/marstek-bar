import Foundation

/// The assumptions behind the runtime forecast, as plain data.
///
/// Each row is one appliance: the power it draws while running, how long one use
/// lasts, and how many times a day it is used in each scenario. A kettle does not
/// run for an hour: it draws 2000 W for the three minutes the water needs to boil.
/// Always-on devices are written as 24 uses of 60 minutes; a fridge as the share of
/// each hour its compressor runs.
///
/// The numbers are typical household averages. If yours differ, or an appliance is
/// missing, edit the table and open a pull request.
enum UsageProfiles {
    enum Scenario: Int, CaseIterable {
        case economy   // only what is needed
        case moderate  // everyday use, heavy appliances kept short
        case noSaving  // nothing is held back
    }

    struct Appliance {
        let name: String.LocalizationValue
        let watts: Double
        let minutesPerUse: Double
        let usesPerDay: [Double] // indexed by Scenario

        init(_ name: String.LocalizationValue, _ watts: Double, _ minutesPerUse: Double, _ usesPerDay: [Double]) {
            self.name = name
            self.watts = watts
            self.minutesPerUse = minutesPerUse
            self.usesPerDay = usesPerDay
        }
    }

    static let appliances: [Appliance] = [
        //                                      uses per day
        //   name               watts  min/use  [economy, moderate, no saving]
        .init("Router",            15,   60,    [24,  24,  24]),
        .init("Fridge",           120,   20,    [24,  24,  24]),
        .init("Lighting",          40,   60,    [ 3,   5,   8]),
        .init("Laptop",            60,   60,    [ 4,   8,  10]),
        .init("Kettle",          2000,    3,    [ 2,   4,   8]), // one boil
        .init("Coffee machine",  1300,    2,    [ 1,   3,   6]), // one cup
        .init("Microwave",       1000,    3,    [ 0,   2,   4]),
        .init("TV",               100,   60,    [ 0,   2,   5]),
        .init("Cooktop",         1800,   20,    [ 0,   1,   3]),
        .init("Washing machine",  700,   60,    [ 0, 0.5,   1]), // average over a cycle
    ]

    /// Energy of one day in the scenario, spread evenly over 24 hours.
    static func averageWatts(_ scenario: Scenario, appliances: [Appliance] = appliances) -> Double {
        appliances.reduce(0) { $0 + $1.watts * $1.minutesPerUse / 60 * $1.usesPerDay[scenario.rawValue] } / 24
    }

    /// What the scenario consists of, e.g. "Kettle ×2, Coffee machine ×1".
    static func summary(_ scenario: Scenario) -> String {
        appliances.compactMap { appliance in
            let uses = appliance.usesPerDay[scenario.rawValue]
            guard uses > 0 else { return nil }
            // Always-on rows would read as "×24"; the name alone says enough.
            let count = appliance.minutesPerUse >= 20 && uses >= 24 ? "" : " ×\(uses.formatted())"
            return String(localized: appliance.name) + count
        }.joined(separator: ", ")
    }

    #if DEBUG
    static func selfCheck() {
        assert(appliances.allSatisfy { $0.usesPerDay.count == Scenario.allCases.count })
        let kettle = [Appliance("Kettle", 2000, 3, [2, 4, 8])]
        assert(averageWatts(.economy, appliances: kettle) == 200.0 / 24) // two boils of 100 Wh
        assert(averageWatts(.economy) < averageWatts(.moderate))
        assert(averageWatts(.moderate) < averageWatts(.noSaving))
    }
    #endif
}
