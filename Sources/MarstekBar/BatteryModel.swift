import AppKit

struct Snapshot {
    let soc: Int
    let mode: String
    let ongridPower: Double
    let offgridPower: Double
    let temperature: Double?
    let remainingWh: Double?
    let ratedWh: Double?
    let date: Date

    /// Net battery output in watts. Assumes positive values mean discharge.
    var netPower: Double { ongridPower + offgridPower }
}

struct HistoryPoint {
    let date: Date
    let soc: Int
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

    private let client = MarstekClient()
    private let queue = DispatchQueue(label: "marstekbar.poll")
    private var timer: Timer?
    private var failures = 0 // touched only on `queue`
    private var isPolling = false // touched only on the main thread

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey)
        deviceName = UserDefaults.standard.string(forKey: Self.deviceKey) ?? "Marstek"
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

    var title: String {
        guard let snapshot else { return "—" }
        return "\(snapshot.soc)%"
    }

    var iconName: String {
        guard let snapshot else { return "bolt.slash" }
        if isStale { return "exclamationmark.triangle" }
        if snapshot.netPower < -20 { return "battery.100percent.bolt" }
        switch snapshot.soc {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Human readable estimate of time to empty (discharging) or to full (charging).
    var estimate: String? {
        guard let snapshot, let remaining = snapshot.remainingWh else { return nil }
        let power = snapshot.netPower
        if power > 20 {
            return String(localized: "≈ \(Self.format(hours: remaining / power)) until empty")
        }
        if power < -20, let rated = snapshot.ratedWh, rated > remaining {
            return String(localized: "≈ \(Self.format(hours: (rated - remaining) / -power)) until full")
        }
        return nil
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
            Thread.sleep(forTimeInterval: 1)
            let battery = (try? client.request("Bat.GetStatus", params: ["id": 0], hosts: [ip]))?.result

            guard let soc = Self.number(mode["bat_soc"]) ?? Self.number(battery?["soc"]) else {
                throw MarstekError(message: String(localized: "The response has no state of charge"))
            }
            let snapshot = Snapshot(
                soc: Int(soc.rounded()),
                mode: mode["mode"] as? String ?? "—",
                ongridPower: Self.number(mode["ongrid_power"]) ?? 0,
                offgridPower: Self.number(mode["offgrid_power"]) ?? 0,
                temperature: Self.number(battery?["bat_temp"]),
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
            DispatchQueue.main.async {
                self.isPolling = false
                self.lastError = text
                self.now = Date()
            }
        }
    }

    private func apply(_ snapshot: Snapshot, host: String, deviceName: String?) {
        isPolling = false
        self.snapshot = snapshot
        lastError = nil
        now = Date()

        history.append(HistoryPoint(date: snapshot.date, soc: snapshot.soc))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        if self.host != host {
            self.host = host
            UserDefaults.standard.set(host, forKey: Self.hostKey)
        }
        if let deviceName, self.deviceName != deviceName {
            self.deviceName = deviceName
            UserDefaults.standard.set(deviceName, forKey: Self.deviceKey)
        }
    }

    // MARK: - Helpers

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func format(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes >= 60
            ? String(localized: "\(minutes / 60) h \(minutes % 60) min")
            : String(localized: "\(minutes) min")
    }
}
