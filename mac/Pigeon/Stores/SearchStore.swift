import Foundation
import SwiftData

/// Drives the global full-text search across every persisted post.
///
/// The store is intentionally minimal: it owns the query string, debounces
/// it, runs a SwiftData `FetchDescriptor` against `Post.plainText`, and
/// exposes the resulting array for views to render. Search is offline by
/// design — we read the local store, never the network — so it stays fast
/// and works without bypass infrastructure.
///
/// Performance note: at the current scale (a few hundred posts per channel,
/// a handful of channels) `localizedStandardContains` on `plainText` is
/// trivially fast — the whole working set fits in memory. Past ~10k posts
/// we'll start to feel the linear scan and want either a SQLite FTS index
/// or a tokenised secondary table. Not worth solving until we hit it.
@MainActor
@Observable
final class SearchStore {
    /// User-facing query. Bound to the `.searchable` modifier on `RootView`.
    /// Mutating this kicks off a debounced search via `didSet`.
    var query: String = "" {
        didSet { scheduleSearch() }
    }

    /// Most recent search results, sorted newest-first. Empty when the
    /// trimmed query is empty.
    private(set) var results: [Post] = []

    /// True while a debounced search is pending or running. Surfaced as a
    /// subtle progress indicator in `SearchResultsView`.
    private(set) var isSearching: Bool = false

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Cap on how many matches we surface per query. Beyond a couple hundred
    /// the list stops being browsable; pagination would be a better fix when
    /// we grow into it.
    private static let resultLimit: Int = 200

    /// Debounce window. Long enough to let the user finish typing, short
    /// enough that the result list feels live.
    private static let debounce: Duration = .milliseconds(200)

    init(context: ModelContext) {
        self.context = context
    }

    deinit {
        searchTask?.cancel()
    }

    /// `true` once the user has typed something meaningful. Drives the
    /// detail-pane swap in `RootView`.
    var hasActiveQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            self.runQuery(trimmed)
        }
    }

    private func runQuery(_ trimmed: String) {
        // SwiftData's `#Predicate` macro requires the captured value to be
        // referenced by name from inside the closure — extract a local first
        // so the predicate stays a clean expression.
        let needle = trimmed
        var descriptor = FetchDescriptor<Post>(
            predicate: #Predicate { post in
                post.plainText.localizedStandardContains(needle)
            },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.resultLimit
        results = (try? context.fetch(descriptor)) ?? []
        isSearching = false
    }
}

