import Charts
import ServiceManagement
import SwiftUI

@main
struct MarstekBarApp: App {
    @StateObject private var model = BatteryModel()
    @StateObject private var loginItem = LoginItem()

    var body: some Scene {
        MenuBarExtra {
            DetailView(model: model, loginItem: loginItem)
        } label: {
            Image(systemName: model.iconName)
            Text(model.title)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Launch-at-login state. Kept in an ObservableObject instead of @State because the
/// @State macro plugin is not shipped with the Command Line Tools toolchain.
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

struct DetailView: View {
    @ObservedObject var model: BatteryModel
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.deviceName).font(.headline)
                    Spacer()
                    Text(model.socText).font(.title.monospacedDigit().weight(.semibold))
                }
                if let snapshot = model.snapshot {
                    ProgressView(value: Double(min(max(snapshot.soc, 0), 100)), total: 100)
                        .tint(snapshot.soc <= 20 ? .red : snapshot.soc <= 40 ? .orange : .green)
                        .accessibilityHidden(true) // the percentage above says the same
                    Label(state(of: snapshot), systemImage: flowIcon(of: snapshot))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = model.snapshot {
                // Problems first: they are the reason to open the popover.
                ForEach(model.warnings, id: \.id) { warning in
                    Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }

                section("Power", "bolt.fill") {
                    row("poweroutlet.type.f", "Backup output", watts(snapshot.offgridPower))
                    row("powerplug", "Grid port", watts(snapshot.ongridPower))
                    if let estimate = model.estimate {
                        // The icon carries the direction: spelled out in the value it did not fit the row.
                        row(estimate.untilFull ? "battery.100percent.bolt" : "battery.25percent",
                            "Estimate", estimate.time)
                    }
                }

                section("Battery", "battery.100percent") {
                    if let remaining = snapshot.remainingWh, let rated = snapshot.ratedWh {
                        row("bolt.batteryblock", "Energy", String(localized: "\(Int(remaining)) / \(Int(rated)) Wh"))
                    }
                    if let temperature = snapshot.temperature {
                        row("thermometer.medium", "Temperature", String(format: "%.0f °C", temperature))
                    }
                    if let health = Analytics.health(soc: snapshot.soc, remainingWh: snapshot.remainingWh,
                                                     ratedWh: snapshot.ratedWh) {
                        row("heart", "Battery health", "≈ \(Int((health * 100).rounded()))% · \(grade(health))")
                    }
                }

                if model.history.count > 1 {
                    section("Last 24 hours", "clock.arrow.circlepath") {
                        if let average = Analytics.averageLoad(model.history) {
                            row("gauge.medium", "Average load", watts(average))
                        }
                        if let used = Analytics.utilization(model.history) {
                            row("arrow.down.to.line", "Used", usage(used, ratedWh: snapshot.ratedWh))
                        }
                        Chart(Array(model.history.enumerated()), id: \.offset) { _, point in
                            AreaMark(x: .value("Time", point.date), y: .value("Charge", point.soc))
                                .foregroundStyle(Color.accentColor.opacity(0.25))
                            LineMark(x: .value("Time", point.date), y: .value("Charge", point.soc))
                                .foregroundStyle(Color.accentColor)
                        }
                        .chartYScale(domain: 0...100)
                        // Room on the right so the last time label is not cut off at the edge.
                        .chartXScale(range: .plotDimension(endPadding: 14))
                        .chartYAxis {
                            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                                AxisGridLine()
                                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 3)) {
                                AxisValueLabel(format: .dateTime.hour().minute())
                            }
                        }
                        .font(.caption2)
                        .frame(height: 64)
                        .padding(.top, 4)
                        .accessibilityLabel(Text("Charge history"))
                    }
                }

                if let remaining = snapshot.remainingWh, remaining > 0 {
                    section("Runtime forecast", "hourglass") {
                        // Bars compare the scenarios: the longest one fills the width.
                        let longest = remaining / UsageProfiles.averageWatts(.economy)
                        ForEach(UsageProfiles.Scenario.allCases, id: \.rawValue) { scenario in
                            let watts = UsageProfiles.averageWatts(scenario)
                            let look = look(of: scenario)
                            VStack(spacing: 3) {
                                row(look.icon, look.title, String(localized:
                                    "\(Int(watts.rounded())) W · \(BatteryModel.format(hours: remaining / watts))"))
                                ProgressView(value: min(remaining / watts, longest), total: longest)
                                    .tint(look.color)
                                    .accessibilityHidden(true)
                            }
                            .help(UsageProfiles.summary(scenario))
                        }
                    }
                }

                Text(statusLine(for: snapshot))
                    .font(.caption)
                    .foregroundStyle(model.isStale ? Color.orange : Color.secondary)
            } else {
                Text(model.lastError ?? String(localized: "Searching for the battery…"))
                    .foregroundStyle(.secondary)
            }

            if model.snapshot != nil, let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.set($0) }))
            if let loginError = loginItem.error {
                Text(loginError).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Glass())
    }

    /// A titled card: related rows share one background so the popover scans in blocks.
    private func section<Content: View>(_ title: LocalizedStringKey, _ icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 6) { content() }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ icon: String, _ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            // Fixed width keeps the titles aligned whatever the glyph is.
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            // The value is the point of the row: it keeps its width, the title gives way.
            Text(value).monospacedDigit().layoutPriority(1)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    private func flowIcon(of snapshot: Snapshot) -> String {
        if snapshot.isCharging { return "arrow.up.circle.fill" }
        if snapshot.isDischarging { return "arrow.down.circle.fill" }
        return "pause.circle"
    }

    private func state(of snapshot: Snapshot) -> String {
        let power = Int(abs(snapshot.netPower).rounded())
        if snapshot.isCharging { return String(localized: "Charging \(power) W") }
        if snapshot.isDischarging { return String(localized: "Discharging \(power) W") }
        return String(localized: "Idle")
    }

    private func look(of scenario: UsageProfiles.Scenario) -> (title: LocalizedStringKey, icon: String, color: Color) {
        switch scenario {
        case .economy: return ("Economy", "leaf", .green)
        case .moderate: return ("Moderate use", "house", .orange)
        case .noSaving: return ("No saving", "flame", .red)
        }
    }

    private func grade(_ health: Double) -> String {
        if health >= 0.9 { return String(localized: "Good") }
        if health >= 0.8 { return String(localized: "Fair") }
        return String(localized: "Worn")
    }

    private func usage(_ share: Double, ratedWh: Double?) -> String {
        let percent = "\(Int((share * 100).rounded()))%"
        guard let ratedWh else { return percent }
        return String(localized: "\(Int(share * ratedWh)) Wh") + " · " + percent
    }

    private func watts(_ value: Double) -> String {
        String(localized: "\(Int(value.rounded())) W")
    }

    private func statusLine(for snapshot: Snapshot) -> String {
        let time = snapshot.date.formatted(date: .omitted, time: .shortened)
        let status = model.isStale
            ? String(localized: "Stale data, last updated \(time)")
            : String(localized: "Updated \(time)")
        return "\(status) · \(model.host ?? "—")"
    }
}

/// Translucent popover background: blurs whatever is behind the window.
struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // The MenuBarExtra panel paints its own opaque background over the blur.
        DispatchQueue.main.async {
            view.window?.isOpaque = false
            view.window?.backgroundColor = .clear
        }
    }
}
