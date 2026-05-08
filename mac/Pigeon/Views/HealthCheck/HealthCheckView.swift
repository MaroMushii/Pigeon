import SwiftUI

struct HealthCheckView: View {
    @State private var checker = HealthChecker()
    @State private var results: [EndpointResult] = []
    @State private var isChecking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            resultsList
            Divider()
            footer
        }
        .task { await runChecks() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Network Health")
                .font(.headline)
            Text("Bypass path connectivity status")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { Divider().padding(.leading, 52) }
                EndpointRow(result: result)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Check Again") {
                Task { await runChecks() }
            }
            .disabled(isChecking)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func runChecks() async {
        isChecking = true
        defer { isChecking = false }
        let base = SettingsStore.defaultMirrorBaseURL
        results = EndpointResult.allPending(mirrorBaseURL: base)

        // Each probe streams its row into `results` the moment it resolves —
        // dots appear in completion order, not in declaration order. We probe
        // each pinned IP individually (no rotation) so a single filtered
        // Google frontend shows up as one red dot instead of being masked by
        // the first-success behavior of `getWithIPRotation`.
        // Structured form so cancellation propagates from `.task { runChecks() }`
        // down into the probes if the modal is dismissed mid-check.
        await withTaskGroup(of: EndpointResult.self) { group in
            group.addTask { await checker.checkMirror(baseURL: base) }
            for ip in PinnedHTTPSClient.translateGoogIPs {
                group.addTask { await checker.checkProxy(ip: ip) }
            }
            for await result in group {
                replace(result)
            }
        }
    }

    private func replace(_ updated: EndpointResult) {
        guard let index = results.firstIndex(where: { $0.id == updated.id }) else { return }
        results[index] = updated
    }
}

private struct EndpointRow: View {
    let result: EndpointResult

    var body: some View {
        HStack(spacing: 12) {
            statusIndicator
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.body)
                if case .failed(let msg) = result.status {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            latencyLabel
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch result.status {
        case .pending:
            ProgressView().controlSize(.small)
        case .ok:
            Circle().fill(.green).frame(width: 10, height: 10)
        case .failed:
            Circle().fill(.red).frame(width: 10, height: 10)
        }
    }

    @ViewBuilder
    private var latencyLabel: some View {
        if case .ok(let ms) = result.status {
            Text("\(ms) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
