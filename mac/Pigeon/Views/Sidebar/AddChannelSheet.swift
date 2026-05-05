import SwiftUI
import SwiftData

struct AddChannelSheet: View {
    let service: ChannelService

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var input: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Channel")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste a Telegram channel URL or username.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 8) {
                TextField("@username, t.me/name, or https://t.me/name", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($inputFocused)
                    .onSubmit { Task { await submit() } }
                    .disabled(isLoading)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isLoading)

                Button {
                    Task { await submit() }
                } label: {
                    if isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Adding…")
                        }
                        .frame(minWidth: 80)
                    } else {
                        Text("Add Channel")
                            .frame(minWidth: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .onAppear { inputFocused = true }
    }

    private func submit() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let channel = try await service.addChannel(rawIdentifier: trimmed)
            appState.selectedChannelID = channel.persistentModelID
            dismiss()
        } catch let error as ChannelService.AddError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
