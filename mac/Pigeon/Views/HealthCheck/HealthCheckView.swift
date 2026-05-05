import SwiftUI

struct HealthCheckView: View {
    @State private var checker = HealthChecker()
    @State private var results: [EndpointResult] = EndpointResult.allPending
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
            ForEach(results) { result in
                EndpointRow(result: result)
                if result.id != results.last?.id {
                    Divider().padding(.leading, 52)
                }
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
        results = EndpointResult.allPending
        results = await checker.checkAll()
        isChecking = false
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
