import AppKit
import UserNotifications

struct Snapshot {
    let soc: Int
    let ongridPower: Double
    let offgridPower: Double
    let temperature: Double?
    let remainingWh: Double?
    let ratedWh: Double?
    let date: Date

    /// Net battery output in watts. Assumes positive values mean discharge.
    var netPower: Double { ongridPower + offgridPower }

    /// Below this many watts the battery counts as idle.
    private static let idleBand: Double = 20
    var isCharging: Bool { netPower < -Self.idleBand }
    var isDischarging: Bool { netPower > Self.idleBand }
}

struct HistoryPoint: Codable {
    let date: Date
    let soc: Int
    /// Net battery output in watts; missing in history saved by older versions.
    var power: Double?
}

final class BatteryModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var host: String?
    @Published private(set) var deviceName: String
    @Published private(set) var now = Date()

    private static let hostKey = "host"
    private static let deviceKey = "deviceName"
    private static let pollInterval: TimeInterval = 60
    private static let staleAfter: TimeInterval = 180
    private static let historyLimit = 24 * 60
    private static let lowSoc = 20
    private static let hotTemperature: Double = 50
    private static let offlineAfterFailures = 10 // about ten minutes of failed polls
    private static let historyURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MarstekBar/history.json")

    private let client = MarstekClient()
    private let queue = DispatchQueue(label: "marstekbar.poll")
    private var timer: Timer?
    private var failures = 0 // touched only on `queue`
    private var pollCount = 0 // touched only on `queue`
    private var battery: [String: Any]? // last Bat.GetStatus reply, touched only on `queue`
    private var isPolling = false // touched only on the main thread
    private var notified: Set<String> = [] // alerts already shown, touched only on the main thread

    init() {
        #if DEBUG
        Analytics.selfCheck()
        UsageProfiles.selfCheck()
        #endif
        host = UserDefaults.standard.string(forKey: Self.hostKey)
        deviceName = UserDefaults.standard.string(forKey: Self.deviceKey) ?? "Marstek"
        if let url = Self.historyURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([HistoryPoint].self, from: data) {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            history = saved.filter { $0.date > cutoff }.map {
                // Repairs points saved before the wrapped charging power was fixed.
                HistoryPoint(date: $0.date, soc: $0.soc, power: $0.power.map(Self.signed16))
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 5
        // Timers do not fire right after sleep; wait a little for the network to come back.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
        refresh()
    }

    // MARK: - Derived state for the UI

    var isStale: Bool {
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.date) > Self.staleAfter
    }

    var socText: String {
        guard let snapshot else { return "—" }
        return "\(snapshot.soc)%"
    }

    /// Menu bar title: charge level plus the power flow direction while the data is fresh.
    var title: String {
        guard let snapshot, !isStale else { return socText }
        let watts = abs(snapshot.netPower).rounded()
        // Unlocalized on purpose: the menu bar is short on space.
        let power = watts >= 1000 ? String(format: "%.2f kW", watts / 1000) : "\(Int(watts)) W"
        if snapshot.isCharging { return "\(socText) ↑ \(power)" }
        if snapshot.isDischarging { return "\(socText) ↓ \(power)" }
        return socText
    }

    var iconName: String {
        guard let snapshot else { return "bolt.slash" }
        if isStale { return "exclamationmark.triangle" }
        if snapshot.isCharging { return "battery.100percent.bolt" }
        switch snapshot.soc {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Estimated time to empty (discharging) or to full (charging).
    var estimate: (untilFull: Bool, time: String)? {
        guard let snapshot, let remaining = snapshot.remainingWh else { return nil }
        let power = snapshot.netPower
        if snapshot.isDischarging {
            return (false, "≈ " + Self.format(hours: remaining / power))
        }
        if snapshot.isCharging, let rated = snapshot.ratedWh, rated > remaining {
            return (true, "≈ " + Self.format(hours: (rated - remaining) / -power))
        }
        return nil
    }

    /// Problems worth the user's attention; shown in the popover and sent as notifications.
    var warnings: [(id: String, text: String)] {
        guard let snapshot, !isStale else { return [] }
        var result: [(id: String, text: String)] = []
        if let temperature = snapshot.temperature, temperature >= Self.hotTemperature {
            result.append(("temperature", String(localized: "High temperature: \(Int(temperature.rounded())) °C")))
        }
        if Analytics.isSustained(history, now: snapshot.date) {
            result.append(("load", String(localized:
                "Load above \(Int(Analytics.sustainedWatts)) W for over \(Int(Analytics.sustainedFor / 3600)) h")))
        }
        return result
    }

    // MARK: - Polling

    func refresh() {
        now = Date()
        // One poll at a time: queued polls would hit the device back to back.
        guard !isPolling else { return }
        isPolling = true
        let knownHost = host
        queue.async { [weak self] in self?.poll(knownHost: knownHost) }
    }

    private func poll(knownHost: String?) {
        do {
            var target = knownHost
            var discoveredName: String?

            // Discover on first run, or re-discover after repeated failures (IP may have changed).
            if target == nil || failures >= 3 {
                do {
                    let reply = try client.request("Marstek.GetDevice",
                                                   params: ["ble_mac": "0"],
                                                   hosts: MarstekClient.broadcastAddresses())
                    target = reply.sender
                    discoveredName = reply.result["device"] as? String
                    Thread.sleep(forTimeInterval: 1)
                } catch {
                    // Broadcast may be blocked while the cached address still works.
                    guard knownHost != nil else { throw error }
                }
            }
            guard let ip = target, !ip.isEmpty else {
                throw MarstekError(message: String(localized: "Battery not found on the network"))
            }

            let mode = try client.request("ES.GetMode", params: ["id": 0], hosts: [ip]).result
            // Keep requests spaced out: the device API gets unstable under load.
            // Bat.GetStatus is suspected of resetting some batteries when polled often: ask rarely.
            if pollCount % 5 == 0 || battery == nil {
                Thread.sleep(forTimeInterval: 1)
                if let fresh = (try? client.request("Bat.GetStatus", params: ["id": 0], hosts: [ip]))?.result {
                    battery = fresh
                }
            }
            pollCount += 1

            guard let soc = Self.number(mode["bat_soc"]) ?? Self.number(battery?["soc"]) else {
                throw MarstekError(message: String(localized: "The response has no state of charge"))
            }
            let snapshot = Snapshot(
                soc: Int(soc.rounded()),
                ongridPower: Self.signed16(Self.number(mode["ongrid_power"]) ?? 0),
                offgridPower: Self.signed16(Self.number(mode["offgrid_power"]) ?? 0),
                // Old BMS firmware reports the temperature multiplied by ten.
                temperature: Self.number(battery?["bat_temp"]).map { $0 > 100 ? $0 / 10 : $0 },
                remainingWh: Self.number(battery?["bat_capacity"]),
                ratedWh: Self.number(battery?["rated_capacity"]),
                date: Date())
            failures = 0

            DispatchQueue.main.async {
                self.apply(snapshot, host: ip, deviceName: discoveredName)
            }
        } catch {
            failures += 1
            let text = error.localizedDescription
            let offline = failures >= Self.offlineAfterFailures
            DispatchQueue.main.async {
                self.isPolling = false
                self.lastError = text
                self.now = Date()
                self.alert("offline", active: offline, cleared: false,
                           body: String(localized: "No connection to the battery: \(text)"))
            }
        }
    }

    private func apply(_ snapshot: Snapshot, host: String, deviceName: String?) {
        isPolling = false
        self.snapshot = snapshot
        lastError = nil
        now = Date()

        history.append(HistoryPoint(date: snapshot.date, soc: snapshot.soc, power: snapshot.netPower))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        if let url = Self.historyURL, let data = try? JSONEncoder().encode(history) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        alert("low", active: snapshot.soc <= Self.lowSoc && snapshot.isDischarging,
              cleared: snapshot.soc > Self.lowSoc + 5,
              body: String(localized: "Battery is low: \(snapshot.soc)%"))
        let active = warnings
        for id in ["temperature", "load"] {
            let text = active.first { $0.id == id }?.text
            alert(id, active: text != nil, cleared: text == nil, body: text ?? "")
        }
        notified.remove("offline")
        if self.host != host {
            self.host = host
            UserDefaults.standard.set(host, forKey: Self.hostKey)
        }
        if let deviceName, self.deviceName != deviceName {
            self.deviceName = deviceName
            UserDefaults.standard.set(deviceName, forKey: Self.deviceKey)
        }
    }

    /// One notification per episode: fires when `active`, re-armed once `cleared`.
    private func alert(_ id: String, active: Bool, cleared: Bool, body: String) {
        if cleared { notified.remove(id) }
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
        guard active, !notified.contains(id), Bundle.main.bundleIdentifier != nil else { return }
        notified.insert(id)
        let content = UNMutableNotificationContent()
        content.title = deviceName
        content.body = body
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // MARK: - Helpers

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Some firmware sends negative (charging) power as an unsigned 16-bit number: -1204 W arrives as 64332.
    static func signed16(_ watts: Double) -> Double {
        watts > 32767 ? watts - 65536 : watts
    }

    /// Watts below a kilowatt, kilowatts with two decimals from there on; keeps the sign.
    static func format(watts: Double) -> String {
        let rounded = watts.rounded()
        return abs(rounded) >= 1000
            ? String(localized: "\(String(format: "%.2f", rounded / 1000)) kW")
            : String(localized: "\(Int(rounded)) W")
    }

    static func format(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes >= 60
            ? String(localized: "\(minutes / 60) h \(minutes % 60) min")
            : String(localized: "\(minutes) min")
    }
}
