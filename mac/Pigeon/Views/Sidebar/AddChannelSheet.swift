import SwiftUI
import SwiftData

private struct PopularChannelInfo {
    let username: String
    let displayName: String
}

private let popularChannels: [PopularChannelInfo] = [
    .init(username: "vahidonline",   displayName: "Vahid Online"),
    .init(username: "bbcpersian",    displayName: "BBC Persian"),
    .init(username: "iranintl",      displayName: "Iran International"),
    .init(username: "voafarsi",      displayName: "VOA Farsi"),
    .init(username: "radiofarda",    displayName: "Radio Farda"),
    .init(username: "dwpersian",     displayName: "DW Persian"),
    .init(username: "sahamnewsorg",  displayName: "Saham News"),
    .init(username: "followupiran",  displayName: "Followup Iran"),
    .init(username: "mamlekate",     displayName: "Mamlekate"),
    .init(username: "daadbaan2021",  displayName: "Daadbaan"),
    .init(username: "ircfspace",     displayName: "IRCF"),
    .init(username: "persianvpnhub", displayName: "Persian VPN Hub"),
    .init(username: "iranlix",       displayName: "Iran Lix"),
    .init(username: "matinsenpaii",  displayName: "Matin Sen Paii"),
    .init(username: "no_itsmyturn",  displayName: "No It’s My Turn"),
    .init(username: "telegram",      displayName: "Telegram News"),
    .init(username: "durov",         displayName: "Pavel Durov"),
]

struct AddChannelSheet: View {
    let service: ChannelService

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Query private var existingChannels: [Channel]

    @State private var input: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var inflightChips: Set<String> = []
    @FocusState private var inputFocused: Bool

    private var addedUsernames: Set<String> {
        Set(existingChannels.map { $0.username })
    }

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

            inlineDivider
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView(.vertical) {
                HFlow(spacing: 8, lineSpacing: 8) {
                    ForEach(popularChannels, id: \.username) { channel in
                        PopularChannelChip(
                            username: channel.username,
                            displayName: channel.displayName,
                            state: chipState(for: channel.username),
                            onTap: { Task { await addPopular(channel.username) } }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 140)
            .padding(.bottom, 16)

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
        .frame(minWidth: 460)
        .onAppear { inputFocused = true }
    }

    private var inlineDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.tertiary)
                .frame(height: 1)
            Text("Or add popular channels")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(.tertiary)
                .frame(height: 1)
        }
    }

    private func chipState(for username: String) -> PopularChannelChip.State {
        if addedUsernames.contains(username) { return .added }
        if inflightChips.contains(username) { return .loading }
        return .idle
    }

    private func addPopular(_ username: String) async {
        guard !inflightChips.contains(username), !addedUsernames.contains(username) else { return }
        inflightChips.insert(username)
        errorMessage = nil
        defer { inflightChips.remove(username) }
        do {
            let channel = try await service.addChannel(rawIdentifier: username)
            appState.selectedChannelID = channel.persistentModelID
        } catch let error as ChannelService.AddError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
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

private struct PopularChannelChip: View {
    enum State { case idle, loading, added }

    let username: String
    let displayName: String
    let state: State
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                glyph
                    .frame(width: 12, height: 12)
                Text(displayName)
                    .font(.callout)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background, in: .capsule)
            .overlay(
                Capsule().strokeBorder(borderColor, lineWidth: 1)
            )
            .foregroundStyle(foreground)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(state != .idle)
        .help(helpText)
        .animation(.snappy(duration: 0.18), value: state)
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .idle:
            Image(systemName: "plus")
                .font(.caption2.weight(.bold))
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .added:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
        }
    }

    private var background: AnyShapeStyle {
        switch state {
        case .idle, .loading:
            AnyShapeStyle(Color.secondary.opacity(0.12))
        case .added:
            AnyShapeStyle(Color.accentColor.opacity(0.15))
        }
    }

    private var borderColor: Color {
        switch state {
        case .idle, .loading: Color.secondary.opacity(0.25)
        case .added:          Color.accentColor.opacity(0.35)
        }
    }

    private var foreground: AnyShapeStyle {
        switch state {
        case .idle, .loading: AnyShapeStyle(.primary)
        case .added:          AnyShapeStyle(Color.accentColor)
        }
    }

    private var helpText: String {
        switch state {
        case .idle:    "Add \(displayName) (@\(username)) to your channels"
        case .loading: "Adding \(displayName)…"
        case .added:   "\(displayName) (@\(username)) is already in your sidebar"
        }
    }
}

private struct HFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let advance = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if advance > maxWidth, rowWidth > 0 {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = advance
                rowHeight = max(rowHeight, size.height)
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

