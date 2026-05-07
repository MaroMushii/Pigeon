import Foundation

/// In-memory representation of `health.json` at the export tree root.
/// Written by `mirror/scrape.ts` at the end of every sweep, fetched by
/// `TelegramClient.fetchMirrorHealth(...)`, surfaced in the sidebar
/// footer.
///
/// `generatedAt` is the *sweep finish time* — what makes this strictly
/// better than `Channel.lastFetchedAt` for staleness signalling. The
/// per-channel field tracks when *this app instance* last fetched a
/// snapshot, which conflates user activity with mirror health. The
/// sweep timestamp doesn't.
///
/// `failures` lists channels that threw inside the scraper's per-channel
/// try/catch on this run. An empty array means a clean sweep; a few
/// entries are a normal transient blip; a large fraction is a real
/// problem (DNS at the runner, t.me throttling, parser regression).
struct MirrorHealth: Sendable, Equatable {
    let generatedAt: Date
    let succeeded: Int
    let failures: [Failure]

    struct Failure: Sendable, Equatable {
        let username: String
        let error: String
    }
}

struct MirrorHealthDecoder {
    enum DecodeError: Error, LocalizedError {
        case unsupportedSchema(found: Int, supported: Int)
        case invalidJSON(underlying: Error)
        case invalidTimestamp(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let found, let supported):
                "Mirror health uses unsupported schema v\(found) (this build supports v\(supported))."
            case .invalidJSON(let e):
                "Could not decode mirror health: \(e.localizedDescription)"
            case .invalidTimestamp(let raw):
                "Mirror health timestamp not parseable: \(raw)."
            }
        }
    }

    static let supportedSchemaVersion: Int = 2

    private struct Doc: Decodable {
        let schema: Int
        let generated_at: String
        let succeeded: Int
        let failed: [FailureDTO]
    }

    private struct FailureDTO: Decodable {
        let username: String
        let error: String
    }

    func decode(_ data: Data) throws -> MirrorHealth {
        let doc: Doc
        do {
            doc = try JSONDecoder().decode(Doc.self, from: data)
        } catch {
            throw DecodeError.invalidJSON(underlying: error)
        }

        guard doc.schema == Self.supportedSchemaVersion else {
            throw DecodeError.unsupportedSchema(
                found: doc.schema,
                supported: Self.supportedSchemaVersion
            )
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let altFormatter = ISO8601DateFormatter()
        altFormatter.formatOptions = [.withInternetDateTime]

        guard let generatedAt = formatter.date(from: doc.generated_at)
            ?? altFormatter.date(from: doc.generated_at) else {
            throw DecodeError.invalidTimestamp(doc.generated_at)
        }

        return MirrorHealth(
            generatedAt: generatedAt,
            succeeded: doc.succeeded,
            failures: doc.failed.map { .init(username: $0.username, error: $0.error) }
        )
    }
}

