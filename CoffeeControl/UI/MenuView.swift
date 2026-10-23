import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = Runtime.arguments.contains("--settings")

    var body: some View {
        VStack(spacing: 8) {
            if showSettings {
                SettingsPage { withAnimation(.snappy(duration: 0.25)) { showSettings = false } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainPage()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            FooterBar(showSettings: $showSettings)
        }
        .padding(10)
        .frame(width: 380)
    }
}

/// Main page: three modes. The status line shows what the system really reports (not what the app assumes).
struct MainPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.state
        Module(spacing: 10) {
            HStack(spacing: 10) {
                // Like DeviceBadge, but with its own cup image (a crossed-out cup doesn't exist as an SF Symbol).
                Image(nsImage: CoffeeIcon.image(model.iconMode, pointSize: 13.8, weight: .semibold))
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    SettingNote(status.text, tint: status.color)
                }
                Spacer()
            }
            Picker("Mode", selection: Binding(get: { state.mode }, set: { model.setMode($0) })) {
                Text("Awake").tag(KeepAwake.Mode.awake)
                Text("Normal").tag(KeepAwake.Mode.normal)
                Text("Sleep").tag(KeepAwake.Mode.sleep)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .demoTarget("mode")
            .frame(maxWidth: .infinity)
        }
        TimerModule()
        // Without the helper rule the Mac sleeps with the lid closed anyway: offer the one-time setup right here.
        if !state.helperInstalled {
            Module {
                HStack(spacing: 8) {
                    SettingLabel(symbol: "lock.shield", title: state.mode == .sleep ? "Override needs a one-time setup"
                                                                                    : "Closed lid needs a one-time setup", tint: .orange)
                    Spacer()
                    Button(model.isBusy ? "Waiting…" : "Set Up…") { model.installHelper() }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
                if let error = model.setupError {
                    SettingNote(error, tint: .red)
                }
            }
        }
    }

    private var title: String {
        switch model.state.mode {
        case .awake: "Stay Awake"
        case .normal: "Normal"
        case .sleep: "Force Sleep"
        }
    }

    private var tint: Color {
        switch model.state.mode {
        case .awake: model.state.active ? .brown : .gray
        case .normal: .gray
        case .sleep: .indigo
        }
    }

    private var status: (text: String, color: Color) {
        let state = model.state
        if state.mode == .normal { return ("Off – Mac sleeps normally", .secondary) }
        if state.mode == .sleep {
            if state.sleepDisabled == true { return ("Sleep disabled via pmset – needs setup", .red) }
            if state.blockersOverridden { return ("Ignoring other apps' sleep blocks", .green) }
            return ("Sleeps on idle and lid close · nothing to override", .green)
        }
        if state.pausedOnBattery { return ("Paused on battery – Mac sleeps normally", .orange) }
        if !state.assertionsHeld { return ("Could not block sleep", .red) }
        if state.sleepDisabled != true { return ("Lid open only – closing it still sleeps", .orange) }
        if state.lowPowerActive { return ("Awake with lid closed · Low Power on", .green) }
        return ("Never sleeps · lid closed too", .green)
    }
}

/// Timer: limits the current mode, then switches to Normal or Sleep. Both rows always stay in place;
/// only the note below appears while the timer runs.
struct TimerModule: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Module(spacing: 8) {
            HStack(spacing: 8) {
                SettingLabel(symbol: "timer", title: "Timer", tint: .orange)
                Spacer()
                if model.timerMinutes != nil { TimerNote() }
            }
            // Six segments don't fit next to the label: the picker gets its own full-width row.
            Picker("Timer", selection: Binding(get: { model.timerMinutes ?? 0 }, set: { model.setTimer($0 == 0 ? nil : $0) })) {
                Text("Off").tag(0)
                ForEach(AppModel.timerChoices, id: \.self) { Text(CoffeeTimer.short($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .demoTarget("timer")
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                SettingLabel(symbol: "arrow.turn.down.right", title: "Then", tint: .gray)
                Spacer()
                // The mode that is already on can't follow itself: its segment is disabled.
                Picker("Then", selection: Binding(get: { model.timerTarget }, set: { model.setTimerThen($0) })) {
                    Text("Normal").tag(KeepAwake.Mode.normal).selectionDisabled(model.state.mode == .normal)
                    Text("Sleep").tag(KeepAwake.Mode.sleep).selectionDisabled(model.state.mode == .sleep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .demoTarget("then")
            }
        }
    }
}

/// Own view so only this line follows the minute count – the pickers above stay untouched.
/// Styled like `SettingNote`, but with fixed-width digits and on one line, so a new number never changes the layout.
private struct TimerNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("\(model.timerTarget == .sleep ? "Sleep" : "Normal") in \(model.minutesLeft ?? 0) min")
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.orange)
            .lineLimit(1)
    }
}

/// Footer as in all apps: name on the left, app-specific buttons if any, then Settings and Quit on the right.
struct FooterBar: View {
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("Coffee Control")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            RoundIconButton(symbol: "gearshape.fill", size: 24, active: showSettings, help: "Settings") {
                withAnimation(.snappy(duration: 0.25)) { showSettings.toggle() }
            }
            RoundIconButton(symbol: "power", size: 24, help: "Quit Coffee Control") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 4)
    }
}
