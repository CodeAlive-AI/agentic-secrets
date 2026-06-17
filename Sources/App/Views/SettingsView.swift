import SwiftUI

struct SettingsView: View {
    var store: ManagementStore
    @AppStorage("launchMenuBarStatus") private var launchMenuBarStatus = true
    @AppStorage("defaultUnlockTTL") private var defaultUnlockTTL = 3600.0

    var body: some View {
        TabView {
            Form {
                Toggle("Show menu bar status", isOn: $launchMenuBarStatus)
                Stepper("Default unlock TTL: \(Int(defaultUnlockTTL))s", value: $defaultUnlockTTL, in: 0...3600, step: 60)
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                LabeledContent("State directory", value: store.snapshot?.stateDirectory ?? "Not loaded")
                LabeledContent("Config path", value: store.snapshot?.configPath ?? "Not loaded")
            }
            .padding()
            .tabItem { Label("State", systemImage: "externaldrive") }
        }
        .frame(width: 520, height: 260)
    }
}
