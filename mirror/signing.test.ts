/**
 * Tests for `signing.ts` — the producer half of the Ed25519 trust chain.
 * Pigeon's `MirrorSignatureTests.swift` exercises the consumer half; this
 * file exercises sign/verify roundtrip against `node:crypto`'s own verify,
 * tamper detection, and the env-loading error paths.
 *
 * The seed below corresponds to the placeholder pubkey hardcoded in
 * `mac/Pigeon/Services/MirrorSignature.swift`. Sign/verify here uses the
 * same seed end-to-end — we're checking that `signBytes` produces output
 * Node's own verifier accepts, which is the property both sides depend on.
 *
 * Run with `pnpm test` (uses `tsx --test`).
 */

import { strict as assert } from "node:assert";
import { createPublicKey, verify } from "node:crypto";
import { test } from "node:test";

// Reset env per test so the cached key in signing.ts can't carry across
// (Node caches module state, so once `loadSigningKey` succeeds the cache
// hides any later env-var bugs from us). The module is re-imported by
// `await import` in each test that cares about the env-var error path.
const PLACEHOLDER_SEED_B64 = "nxQ9/wY/XYJDJ8DxIjTX+chBI9Y3U55dAXUMoWCoWsE=";
const PLACEHOLDER_PUB_B64 = "17hNErzo6LqtLCXoCRmBFrjBcA5AtveTBwCEqpkJK8A=";

// SPKI DER prefix for Ed25519 public keys — wraps the 32-byte raw key into
// a PKCS-style blob that `createPublicKey` can parse without JWK detours.
const SPKI_ED25519_PREFIX = Buffer.from([
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
  0x70, 0x03, 0x21, 0x00,
]);

function makePublicKey(): import("node:crypto").KeyObject {
  const raw = Buffer.from(PLACEHOLDER_PUB_B64, "base64");
  return createPublicKey({
    key: Buffer.concat([SPKI_ED25519_PREFIX, raw]),
    format: "der",
    type: "spki",
  });
}

test("signBytes produces a 64-byte signature", async () => {
  process.env.MIRROR_SIGNING_KEY = PLACEHOLDER_SEED_B64;
  const { signBytes } = await import("./signing.js");
  const sig = signBytes(Buffer.from("hello mirror"));
  assert.equal(sig.length, 64);
});

test("signBytes output verifies against the matching public key", async () => {
  process.env.MIRROR_SIGNING_KEY = PLACEHOLDER_SEED_B64;
  const { signBytes } = await import("./signing.js");
  const payload = Buffer.from("hello mirror");
  const sig = signBytes(payload);
  assert.ok(verify(null, payload, makePublicKey(), sig));
});

test("verification fails on tampered payload", async () => {
  process.env.MIRROR_SIGNING_KEY = PLACEHOLDER_SEED_B64;
  const { signBytes } = await import("./signing.js");
  const payload = Buffer.from("hello mirror");
  const sig = signBytes(payload);
  const tampered = Buffer.from(payload);
  tampered[0] ^= 0xff;
  assert.equal(verify(null, tampered, makePublicKey(), sig), false);
});

test("verification fails on tampered signature", async () => {
  process.env.MIRROR_SIGNING_KEY = PLACEHOLDER_SEED_B64;
  const { signBytes } = await import("./signing.js");
  const payload = Buffer.from("hello mirror");
  const sig = Buffer.from(signBytes(payload));
  sig[0] ^= 0xff;
  assert.equal(verify(null, payload, makePublicKey(), sig), false);
});

test("sha256Hex of empty input matches RFC 6234 vector", async () => {
  process.env.MIRROR_SIGNING_KEY = PLACEHOLDER_SEED_B64;
  const { sha256Hex } = await import("./signing.js");
  assert.equal(
    sha256Hex(Buffer.alloc(0)),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  );
});

test("sha256Hex of 'abc' matches NIST vector", async () => {
  process.env.MIRROR_SIGNING_KEY = PLACEHOLDER_SEED_B64;
  const { sha256Hex } = await import("./signing.js");
  assert.equal(
    sha256Hex(Buffer.from("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  );
});

// Env-var error paths use a separate worker process so the cached key
// from earlier tests can't leak across. node:test runs each file in its
// own process but caches inside the file are shared across tests, so we
// reach for child_process here rather than fiddling with require cache.
test("missing MIRROR_SIGNING_KEY throws synchronously", async () => {
  const { spawnSync } = await import("node:child_process");
  const result = spawnSync(
    process.execPath,
    ["--import", "tsx", "-e", "import('./signing.js').then(({signBytes}) => signBytes(Buffer.from('x'))).catch(e => { process.stderr.write(e.message); process.exit(1); });"],
    {
      cwd: import.meta.dirname,
      env: { ...process.env, MIRROR_SIGNING_KEY: "" },
      encoding: "utf8",
    }
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /MIRROR_SIGNING_KEY/);
});

test("wrong-size MIRROR_SIGNING_KEY throws synchronously", async () => {
  const { spawnSync } = await import("node:child_process");
  // 16 bytes of base64 — too short. signing.ts must reject.
  const shortKey = Buffer.alloc(16).toString("base64");
  const result = spawnSync(
    process.execPath,
    ["--import", "tsx", "-e", "import('./signing.js').then(({signBytes}) => signBytes(Buffer.from('x'))).catch(e => { process.stderr.write(e.message); process.exit(1); });"],
    {
      cwd: import.meta.dirname,
      env: { ...process.env, MIRROR_SIGNING_KEY: shortKey },
      encoding: "utf8",
    }
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /32 bytes/);
});
