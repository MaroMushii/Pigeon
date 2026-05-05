import SwiftUI

/// macOS Settings scene contents. Standard `Form` with three sections —
/// General, Mirror, About. Hosted by the App's `Settings { }` scene, so
/// ⌘, opens it without any custom plumbing.
///
/// The Mirror section is the load-bearing one: when GitHub raw is blocked
/// in a region, users can paste an alternative base URL and keep working
/// without waiting for a new release.
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
            }

            Section {
                TextField(
                    "Custom mirror base URL",
                    text: $settings.mirrorBaseURL,
                    prompt: Text(verbatim: Self.defaultMirrorPlaceholder)
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                mirrorValidationHint

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
            } header: {
                Text("Mirror")
            } footer: {
                Text("Snapshots are appended as `/channels/<username>/snapshot.json`. Leave blank to use the bundled GitHub mirror.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .frame(minHeight: 360)
    }

    @ViewBuilder
    private var mirrorValidationHint: some View {
        let trimmed = settings.mirrorBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text("Using the bundled mirror.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if settings.validatedMirrorBaseURL == nil {
            Label("Must start with https:// and be a valid URL.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else {
            Label("Looks good.", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        }
    }

    private static let defaultMirrorPlaceholder =
        "https://raw.githubusercontent.com/MaroMushii/Pigeon/refs/heads/export"

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

