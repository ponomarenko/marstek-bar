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
                Text(model.title).font(.title2.monospacedDigit().weight(.semibold))
            }

            if let snapshot = model.snapshot {
                VStack(spacing: 4) {
                    row("Mode", snapshot.mode)
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
                    Sparkline(values: model.history.map { Double($0.soc) })
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .frame(height: 36)
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
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
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

/// State-of-charge history drawn on a fixed 0–100 scale.
struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let clamped = min(max(value, 0), 100)
            let point = CGPoint(x: rect.minX + CGFloat(index) * step,
                                y: rect.maxY - rect.height * CGFloat(clamped / 100))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
