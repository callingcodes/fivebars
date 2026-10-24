import ServiceManagement
import SwiftUI

/// The settings window, mirroring the original's preference pane.
struct SettingsView: View {
    let monitor: Monitor
    let updater: Updater

    @State private var hostDraft = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var checkAutomatically = false
    @State private var installAutomatically = false
    @State private var lastChecked: Date?
    @FocusState private var hostFocused: Bool

    private var prefs: Preferences { monitor.prefs }

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                TextField("Host to Ping", text: $hostDraft)
                    .focused($hostFocused)
                    .onSubmit(commitHost)
                    .onChange(of: hostFocused) { _, focused in
                        if !focused { commitHost() }
                    }
                if let address = addressLine {
                    LabeledContent("Address", value: address)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                footerText(
                    "Fivebars constantly pings this host to measure the quality of your internet "
                        + "connection. The bars show signal strength based on recent latency and packet loss."
                )
            }

            Section {
                LabeledContent("Slow Ping Threshold") {
                    HStack {
                        Slider(value: logThreshold, in: log(Preferences.slowPingRange.lowerBound)...log(
                            Preferences.slowPingRange.upperBound
                        ))
                        Text("\(Int(prefs.slowPingThresholdMs)) ms")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            } footer: {
                footerText(
                    "Pings faster than the threshold count as perfect. Slower pings lower the signal "
                        + "strength until it reaches zero at threshold + 900 ms."
                )
            }

            Section {
                Picker("Display", selection: $prefs.display) {
                    ForEach(Preferences.Display.allCases) { display in
                        Text(display.title).tag(display)
                    }
                }
                Toggle("Packet Loss Text", isOn: $prefs.showPacketLossText)
                Toggle("Connection Up/Down Alerts", isOn: $prefs.showNotifications)
                    .onChange(of: prefs.showNotifications) { _, enabled in
                        if enabled { Notifier.shared.requestAuthorization() }
                    }
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if Updater.isAvailable {
                Section {
                    Toggle("Check for Updates Automatically", isOn: $checkAutomatically)
                        .onChange(of: checkAutomatically) { _, enabled in
                            updater.automaticallyChecksForUpdates = enabled
                        }
                    Toggle("Install Updates Automatically", isOn: $installAutomatically)
                        .disabled(!checkAutomatically)
                        .onChange(of: installAutomatically) { _, enabled in
                            updater.automaticallyDownloadsUpdates = enabled
                        }
                    LabeledContent("Last Checked") {
                        HStack {
                            Text(lastCheckedText)
                                .foregroundStyle(.secondary)
                            let action = { updater.checkForUpdates(nil) }
                            Button(action: action) {
                                Text("Check Now")
                            }
                        }
                    }
                } footer: {
                    footerText(
                        "Once a day, Fivebars asks callingcodes.com whether a newer version exists. "
                            + "You are asked before an update is installed, unless you turn on automatic installs."
                    )
                }
            }

            Section {
                HStack {
                    Spacer()
                    let action = {
                        monitor.restoreDefaults()
                        hostDraft = monitor.prefs.hostname
                    }
                    Button(action: action) {
                        Text("Restore Default Settings")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            hostDraft = prefs.hostname
            launchAtLogin = LaunchAtLogin.isEnabled
            checkAutomatically = updater.automaticallyChecksForUpdates
            installAutomatically = updater.automaticallyDownloadsUpdates
            lastChecked = updater.lastUpdateCheckDate
        }
    }

    private var lastCheckedText: String {
        guard let lastChecked else { return "Never" }
        return lastChecked.formatted(date: .abbreviated, time: .shortened)
    }

    /// The resolved address, or the resolver's state; hidden when it would just repeat a literal IP host.
    private var addressLine: String? {
        if let address = monitor.resolvedAddress {
            return address == prefs.hostname ? nil : address
        }
        if monitor.status == .down, monitor.lastError != nil {
            return monitor.downReasonText
        }
        return "Resolving…"
    }

    /// The threshold slider runs on a log scale so the useful 50–300 ms band gets half the track.
    /// No `step:`, which draws unlabeled tick marks; values snap to 10 ms instead.
    private var logThreshold: Binding<Double> {
        Binding(
            get: { log(prefs.slowPingThresholdMs) },
            set: { value in
                let ms = (exp(value) / 10).rounded() * 10
                let range = Preferences.slowPingRange
                prefs.slowPingThresholdMs = min(max(ms, range.lowerBound), range.upperBound)
            }
        )
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitHost() {
        monitor.setHostname(hostDraft)
        hostDraft = monitor.prefs.hostname
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else {
            launchError = nil
            return
        }
        do {
            try LaunchAtLogin.set(enabled)
            launchError = nil
            if SMAppService.mainApp.status == .requiresApproval {
                launchError = "Approve Fivebars in System Settings > Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
