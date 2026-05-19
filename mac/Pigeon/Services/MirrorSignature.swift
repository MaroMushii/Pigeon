import CryptoKit
import Foundation

/// Verifies Ed25519 detached signatures on mirror snapshots (`snapshot.json`,
/// `index.json`) and SHA-256 hashes on referenced media bytes.
///
/// This is the trust anchor that lets Pigeon fetch from untrusted Iran-domestic
/// GitHub mirrors (`scorpian.ir/raw/...` and similar). Without verification, a
/// mirror operator could inject fake posts, fake reactions, or rewrite image
/// URLs to malicious hosts. With it, every byte the app displays is byte-for-byte
/// what the GitHub Actions workflow signed.
///
/// The public key is hardcoded — rotation requires shipping a new app version.
/// The corresponding private seed lives in the `MIRROR_SIGNING_KEY` GH Actions
/// secret; see `mirror/keygen.ts` and `mirror/signing.ts`.
///
/// Freshness defence: a malicious mirror can't forge new signatures, but it
/// *can* serve a stale-but-valid snapshot from days ago. `maxFreshnessAge`
/// rejects snapshots whose `fetched_at` is too far in the past. The mirror
/// cron runs every 5 min, so 24 h is a generous tolerance window.
enum MirrorSignature {

    /// Ed25519 public key matching the `MIRROR_SIGNING_KEY` private seed.
    /// 32 raw bytes, base64-encoded for source readability.
    ///
    /// REPLACE BEFORE SHIPPING. The value below is a placeholder generated
    /// during initial development — anyone reading this file in git history
    /// has the matching private key. Generate a real keypair with
    /// `pnpm exec tsx mirror/keygen.ts`, paste the base64 public key here,
    /// and stash the private seed in your password manager + the
    /// `MIRROR_SIGNING_KEY` GH Actions secret.
    private static let publicKeyBase64 = "17hNErzo6LqtLCXoCRmBFrjBcA5AtveTBwCEqpkJK8A="

    /// Sentinel: the development placeholder key. Release builds trap on
    /// startup if `publicKeyBase64` still matches this — shipping an app
    /// whose verification key has a publicly-known matching private seed
    /// would be worse than no verification at all (false sense of security).
    private static let placeholderPublicKeyBase64 = "17hNErzo6LqtLCXoCRmBFrjBcA5AtveTBwCEqpkJK8A="

    /// How old a snapshot can be (relative to its `fetched_at`) before we
    /// reject it as stale. 24 h is loose enough to tolerate a brief mirror
    /// outage, tight enough that rollback attacks can't replay last week's
    /// snapshot to suppress current posts.
    static let maxFreshnessAge: TimeInterval = 24 * 60 * 60

    /// How far into the future a `fetched_at` may be before we reject it.
    /// Only meant to absorb client/server clock skew — a snapshot legitimately
    /// dated minutes ahead can happen; one dated hours ahead is either a
    /// broken producer or a rollback-then-replay attempt with a forged stamp.
    static let maxClockSkew: TimeInterval = 5 * 60

    static let publicKey: Curve25519.Signing.PublicKey = {
        #if !DEBUG
        if publicKeyBase64 == placeholderPublicKeyBase64 {
            fatalError("MirrorSignature.publicKeyBase64 is still the development placeholder — rotate before shipping a release build")
        }
        #endif
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else {
            // A malformed hardcoded constant is a programmer error, not a
            // runtime condition — trap loudly so it's caught the first time
            // anyone runs the app after a botched paste.
            fatalError("MirrorSignature.publicKeyBase64 is not a valid 32-byte Ed25519 public key")
        }
        return key
    }()

    /// Verify `signature` against `payload` using the embedded public key.
    /// Returns `false` on any failure — tampering, wrong key, malformed sig.
    /// Never throws; callers route the false return to a tier fallback or a
    /// hard error UI state.
    static func verify(payload: Data, signature: Data) -> Bool {
        publicKey.isValidSignature(signature, for: payload)
    }

    /// SHA-256 of `data` as a lowercase hex string. Used to verify downloaded
    /// media bytes against the hash embedded in a (signature-verified) snapshot.
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns `true` if `fetchedAt` is within `maxFreshnessAge` of `now`.
    /// `now` is injected so tests can run against fixed dates without time
    /// travel; production passes `.now`.
    static func isFresh(fetchedAt: Date, now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        // Past window is generous (mirror outage tolerance). Future window is
        // tight — only meant to absorb clock skew, not legitimate "ahead" data.
        return age >= -maxClockSkew && age <= maxFreshnessAge
    }
}
