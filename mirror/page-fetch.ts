/**
 * Channel-page fetch with bounded retries. Own module so tests can import
 * it without executing scrape.ts's CLI entry path.
 */

const ATTEMPTS = 3; // 1 try + 2 retries
const BASE_DELAY_MS = 1_000;
const JITTER_MS = 500;

/** Transient responses worth a retry. 404 and other 4xx fail fast — the
 *  handle is gone or blocked, retrying won't change that. */
const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);

/**
 * Fetch a `t.me/s/<u>` channel page, retrying transient failures (network
 * errors, timeouts, HTTP 429/5xx) with exponential backoff + jitter so one
 * flaky response doesn't cost the channel a whole cron tick. Anything that
 * escapes `fetch` itself is network-level and always retryable.
 */
export async function fetchChannelPage(url: string): Promise<Response> {
  for (let attempt = 1; ; attempt++) {
    let failure: unknown;
    try {
      const res = await fetch(url, {
        signal: AbortSignal.timeout(15_000),
        headers: {
          "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
          Accept:
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language": "en-US,en;q=0.9",
        },
      });
      if (res.ok || !TRANSIENT_STATUSES.has(res.status)) return res;
      failure = new Error(`HTTP ${res.status}`);
    } catch (error) {
      failure = error;
    }
    if (attempt === ATTEMPTS) throw failure;
    const delay =
      BASE_DELAY_MS * 2 ** (attempt - 1) + Math.floor(Math.random() * JITTER_MS);
    process.stderr.write(
      `  retry ${attempt}/${ATTEMPTS - 1} for ${url} in ${delay}ms — ${
        (failure as Error).message
      }\n`
    );
    await sleep(delay);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
