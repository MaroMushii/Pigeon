import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { fetchChannelPage } from "./page-fetch.js";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** Stub global fetch with a scripted sequence of responses/errors. */
function stubFetch(handlers: Array<() => Response>): { calls: () => number } {
  let calls = 0;
  globalThis.fetch = ((): Promise<Response> => {
    const handler = handlers[calls];
    if (!handler) throw new Error("stubFetch: more calls than handlers");
    calls++;
    return Promise.resolve(handler());
  }) as typeof fetch;
  return { calls: () => calls };
}

describe("fetchChannelPage", () => {
  it("retries a transient 503 and returns the eventual 200", async () => {
    const stub = stubFetch([
      () => new Response(null, { status: 503 }),
      () => new Response("<html></html>", { status: 200 }),
    ]);

    const res = await fetchChannelPage("https://t.me/s/durov");

    assert.equal(res.status, 200);
    assert.equal(stub.calls(), 2);
  });

  it("fails fast on a 404 without retrying", async () => {
    const stub = stubFetch([() => new Response(null, { status: 404 })]);

    // Contract: non-transient responses are returned as-is; the caller
    // (scrapeChannel) throws on !res.ok.
    const res = await fetchChannelPage("https://t.me/s/gone");

    assert.equal(res.status, 404);
    assert.equal(stub.calls(), 1);
  });
});
