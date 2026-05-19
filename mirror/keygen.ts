/**
 * One-off Ed25519 keypair generator for the mirror signing scheme.
 *
 * Run once locally:
 *
 *   pnpm exec tsx mirror/keygen.ts
 *
 * Outputs the base64 private seed (32 bytes) and base64 public key (32
 * bytes). The private seed goes into:
 *   1. your password manager (offline backup), and
 *   2. the `MIRROR_SIGNING_KEY` GH Actions secret
 *      (`gh secret set MIRROR_SIGNING_KEY -b "<base64-seed>"`).
 * The public key is pasted into the hardcoded constant in
 * `mac/Pigeon/Services/MirrorSignature.swift`.
 *
 * The PKCS8 DER export prepends a 16-byte header before the seed; the SPKI
 * DER export prepends a 12-byte header before the raw public key. Both are
 * stripped here so what's printed are the *raw* 32-byte values, which is
 * what `crypto.createPrivateKey` in `signing.ts` and CryptoKit's
 * `Curve25519.Signing.PublicKey(rawRepresentation:)` both expect.
 */

import { generateKeyPairSync } from "node:crypto";

const { privateKey, publicKey } = generateKeyPairSync("ed25519");

const pkcs8 = privateKey.export({ format: "der", type: "pkcs8" });
const spki = publicKey.export({ format: "der", type: "spki" });

// PKCS8 ed25519: 16 bytes of header + 32 bytes seed = 48 bytes.
// SPKI ed25519:  12 bytes of header + 32 bytes pubkey = 44 bytes.
const seed = pkcs8.subarray(16);
const pub = spki.subarray(12);

if (seed.length !== 32 || pub.length !== 32) {
  process.stderr.write(
    `unexpected key sizes (seed=${seed.length}, pub=${pub.length}); aborting\n`
  );
  process.exit(1);
}

process.stdout.write(
  [
    "# Pigeon mirror signing keypair",
    "# Keep the private seed offline (password manager) AND set it as",
    "# the MIRROR_SIGNING_KEY GH Actions secret. Paste the public key",
    "# into mac/Pigeon/Services/MirrorSignature.swift.",
    "",
    `PRIVATE_SEED_BASE64=${seed.toString("base64")}`,
    `PUBLIC_KEY_BASE64=${pub.toString("base64")}`,
    "",
  ].join("\n")
);
