import SwiftUI

/// Second page in the menu: battery operation, low power mode on lid close, helper rule, autostart and version.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                RoundIconButton(symbol: "chevron.left", size: 24, help: "Back", action: back)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 2)

            Module {
                HStack {
                    SettingLabel(symbol: "battery.75percent", title: "Also on Battery", tint: .green)
                    Spacer()
                    Toggle("Also on Battery", isOn: Binding(get: { model.awakeOnBattery }, set: { model.setAwakeOnBattery($0) }))
                        .labelsHidden()
                        .toggleStyle(.setting)
                        .controlSize(.small)
                }
                SettingNote(model.awakeOnBattery ? "Stays awake on battery too, until the battery runs low."
                            : "On battery the Mac sleeps normally until you plug it in.")
            }

            Module {
                HStack {
                    SettingLabel(symbol: "leaf.fill", title: "Low Power Mode When Closed", tint: .yellow)
                    Spacer()
                    Toggle("Low Power Mode When Closed", isOn: Binding(get: { model.lowPowerWhenClosed }, set: { model.setLowPowerWhenClosed($0) }))
                        .labelsHidden()
                        .toggleStyle(.setting)
                        .controlSize(.small)
                }
                SettingNote("Saves energy while the lid is closed; your setting returns when you open it.")
            }

            Module {
                HStack {
                    SettingLabel(symbol: "lock.shield", title: "Sleep Rule", tint: .blue)
                    Spacer()
                    Text(model.state.helperInstalled ? "Installed" : "Not installed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(model.state.helperInstalled ? .green : .orange)
                    Button(model.isBusy ? "Waiting…" : (model.state.helperInstalled ? "Remove…" : "Install…")) {
                        if model.state.helperInstalled { model.removeHelper() } else { model.installHelper() }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
                SettingNote("Lets Coffee Control turn off sleep (pmset) without asking for your password – also with the lid closed.")
                if let error = model.setupError {
                    SettingNote(error, tint: .red)
                }
            }

            Module {
                HStack {
                    SettingLabel(symbol: "power", title: "Open at Login", tint: .green)
                    Spacer()
                    Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
                        .labelsHidden()
                        .toggleStyle(.setting)
                        .controlSize(.small)
                }
                SettingNote("Starts Coffee Control automatically when you log in.")
            }

            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                Spacer()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
        }
    }
}
