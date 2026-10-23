import SwiftUI

/// Second page in the menu: battery operation, low power mode on lid close, timer, helper rule, autostart and version.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                RoundIconButton(symbol: "chevron.left", size: 24, help: "Back", action: back)
                    .demoTarget("back")
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
                    SettingLabel(symbol: "timer", title: "Timer", tint: .orange)
                    Spacer()
                    Toggle("Timer", isOn: Binding(get: { model.showTimer }, set: { model.setShowTimer($0) }))
                        .labelsHidden()
                        .toggleStyle(.setting)
                        .controlSize(.small)
                }
                SettingNote("Shows a timer in the menu: keep a mode for a while, then switch to Normal or Sleep.")
                if model.showTimer { TimerChoicesEditor() }
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

            UpdateSettings()

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

/// The timer's durations: click one to remove it, type a new one in minutes or hours to add it.
private struct TimerChoicesEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft = Runtime.value(after: "--draft") ?? ""   // snapshots: a typed duration
    @State private var invalid = false

    private var full: Bool { model.timerChoices.count >= CoffeeTimer.maxChoices }

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(model.timerChoices, id: \.self) { minutes in
                Button { model.removeTimerChoice(minutes) } label: {
                    HStack(spacing: 4) {
                        Text(CoffeeTimer.short(minutes)).font(.system(size: 11).monospacedDigit())
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.16), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.timerChoices.count == 1)
                .help("Remove \(CoffeeTimer.short(minutes))")
            }
        }
        HStack(spacing: 6) {
            TextField("Duration", text: $draft, prompt: Text("e.g. 45m or 8h"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(add)
                .onChange(of: draft) { invalid = false }
                .demoTarget("duration")
            Button("Add", action: add)
                .controlSize(.small)
                .demoTarget("add")
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .disabled(full)
        SettingNote(invalid ? "Type minutes or hours, e.g. 45m, 8h or 1h 30m."
                    : full ? "Up to \(CoffeeTimer.maxChoices) durations – remove one to add another."
                    : "Durations in the menu. Click one to remove it.",
                    tint: invalid ? .red : nil)
    }

    private func add() {
        guard !full else { return }
        if model.addTimerChoice(draft) { draft = "" } else { invalid = true }
    }
}
