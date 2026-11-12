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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.deviceName).font(.headline)
                Spacer()
                Text(model.socText).font(.title2.monospacedDigit().weight(.semibold))
            }

            if let snapshot = model.snapshot {
                VStack(spacing: 4) {
                    row("Status", state(of: snapshot))
                    row("Backup output", watts(snapshot.offgridPower))
                    row("Grid port", watts(snapshot.ongridPower))
                    if let remaining = snapshot.remainingWh, let rated = snapshot.ratedWh {
                        row("Energy", String(localized: "\(Int(remaining)) / \(Int(rated)) Wh"))
                    }
                    if let temperature = snapshot.temperature {
                        row("Temperature", String(format: "%.0f °C", temperature))
                    }
                    if let estimate = model.estimate {
                        row("Estimate", estimate)
                    }
                }

                if model.history.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Charge history").font(.caption2).foregroundStyle(.secondary)
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
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(Glass())
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func state(of snapshot: Snapshot) -> String {
        let power = Int(abs(snapshot.netPower).rounded())
        if snapshot.isCharging { return String(localized: "Charging \(power) W") }
        if snapshot.isDischarging { return String(localized: "Discharging \(power) W") }
        return String(localized: "Idle")
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
