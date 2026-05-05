import SwiftUI

/// macOS Settings scene contents. Hosted by the App's `Settings { }` scene,
/// so ⌘, opens it without any custom plumbing.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(SettingsStore.LogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    value: $settings.cacheTTLMinutes,
                    in: SettingsStore.cacheTTLRange,
                    step: 5
                ) {
                    LabeledContent("Cache freshness") {
                        Text("\(settings.cacheTTLMinutes) min")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Self.appVersion)
                Link(
                    "GitHub repository",
                    destination: URL(string: "https://github.com/MaroMushii/Pigeon")!
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 280)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(SettingsStore())
}

