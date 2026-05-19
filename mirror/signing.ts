/**
 * Ed25519 signing helpers for the mirror's snapshot + index documents.
 *
 * Writes detached `.sig` files alongside every published JSON document so
 * downstream consumers can verify integrity independently of the transport.
 *
 * Private key lives in the `MIRROR_SIGNING_KEY` GH Actions secret as a
 * base64-encoded 32-byte ed25519 seed. The Node `crypto.createPrivateKey`
 * API needs a PKCS8-wrapped key, so we prepend the fixed PKCS8 prefix at
 * load time. See `keygen.ts` for the one-off generator.
 */

import { createHash, createPrivateKey, sign, type KeyObject } from "node:crypto";
import { atomicWriteFile } from "./fs-utils.js";

const ENV_VAR = "MIRROR_SIGNING_KEY";

/**
 * Fixed PKCS8 DER prefix for Ed25519 private keys. Wrapping the raw 32-byte
 * seed with this lets `createPrivateKey` parse it as a standard pkcs8 blob
 * without depending on JWK or pulling in an external library.
 *
 *   30 2e   SEQUENCE (46 bytes)
 *     02 01 00         INTEGER 0  (PKCS8 version)
 *     30 05 06 03 2b 65 70  AlgorithmIdentifier: id-Ed25519 (1.3.101.112)
 *     04 22            OCTET STRING (34 bytes — the inner blob below)
 *       04 20          OCTET STRING (32 bytes — the seed itself)
 *       <seed: 32 bytes>
 */
const PKCS8_ED25519_PREFIX = Buffer.from([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);

let cachedKey: KeyObject | null = null;

/** Load (and cache) the signing key from the `MIRROR_SIGNING_KEY` env var.
 *  Throws synchronously if the var is missing or malformed — CI must surface
 *  this loudly rather than silently skipping signatures. */
function loadSigningKey(): KeyObject {
  if (cachedKey) return cachedKey;
  const b64 = process.env[ENV_VAR];
  if (!b64) {
    throw new Error(
      `${ENV_VAR} env var not set — refusing to write unsigned mirror data. ` +
        `Set the secret in GH Actions (or pass --unsigned for local fixture runs).`
    );
  }
  const seed = Buffer.from(b64, "base64");
  if (seed.length !== 32) {
    throw new Error(
      `${ENV_VAR} must decode to 32 bytes (got ${seed.length}). Did you paste a base64-encoded ed25519 seed?`
    );
  }
  const der = Buffer.concat([PKCS8_ED25519_PREFIX, seed]);
  cachedKey = createPrivateKey({ key: der, format: "der", type: "pkcs8" });
  return cachedKey;
}

/** Sign `data` with the configured key, returning the 64-byte detached
 *  Ed25519 signature. */
export function signBytes(data: Buffer): Buffer {
  return sign(null, data, loadSigningKey());
}

/**
 * Write `payload` to `path` and its detached signature to `path + ".sig"`.
 * Both writes are atomic individually; a client racing the workflow could
 * still observe an old `.json` paired with a new `.sig` (or vice versa) in
 * the ~1 ms gap between renames. Pigeon handles this by retrying once on
 * verification failure, then advancing to the next mirror tier.
 *
 * The signature is the raw 64-byte output (no PEM, no base64) so the `.sig`
 * file is byte-for-byte the value `crypto.verify(null, payload, pub, sig)`
 * expects.
 */
export function signAndWrite(path: string, payload: Buffer): void {
  const sig = signBytes(payload);
  atomicWriteFile(path, payload);
  atomicWriteFile(`${path}.sig`, sig);
}

/** SHA-256 of a buffer as a lowercase hex string (64 chars). Used by the
 *  scraper to populate `*_sha256` fields on media references so the
 *  snapshot signature transitively covers every downloaded image. */
export function sha256Hex(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}
