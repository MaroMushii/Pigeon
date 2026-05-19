import CryptoKit
import XCTest
@testable import Pigeon

/// Tests for `MirrorSignature` — the trust anchor for everything
/// fetched from untrusted Iran-domestic GitHub mirrors. A regression here
/// silently downgrades the app's security posture, so the boundary cases
/// (tampered payload, wrong-key signature, malformed signature, freshness
/// edges) all need explicit coverage.
///
/// The signing seed below corresponds to the placeholder public key
/// hardcoded in `MirrorSignature.publicKeyBase64`. Once that constant is
/// rotated to a production key, these tests must rotate alongside it (or
/// the tests will start passing only because they're signing with the wrong
/// key and verification fails as expected — which is the WRONG kind of
/// green). If you rotate the pubkey, regenerate this seed via
/// `pnpm exec tsx mirror/keygen.ts` and update both constants together.
final class MirrorSignatureTests: XCTestCase {

    /// Base64 of the 32-byte Ed25519 seed matching the placeholder pubkey
    /// in `MirrorSignature.publicKeyBase64`.
    private static let placeholderSeedBase64 = "nxQ9/wY/XYJDJ8DxIjTX+chBI9Y3U55dAXUMoWCoWsE="

    private func makeSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let seed = try XCTUnwrap(Data(base64Encoded: Self.placeholderSeedBase64))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    // MARK: - verify

    func test_verify_acceptsValidSignature() throws {
        let key = try makeSigningKey()
        let payload = Data("hello mirror".utf8)
        let signature = try key.signature(for: payload)
        XCTAssertTrue(MirrorSignature.verify(payload: payload, signature: signature))
    }

    func test_verify_rejectsTamperedPayload() throws {
        let key = try makeSigningKey()
        let payload = Data("hello mirror".utf8)
        let signature = try key.signature(for: payload)
        var tampered = payload
        tampered[0] ^= 0xFF
        XCTAssertFalse(MirrorSignature.verify(payload: tampered, signature: signature))
    }

    func test_verify_rejectsTamperedSignature() throws {
        let key = try makeSigningKey()
        let payload = Data("hello mirror".utf8)
        var signature = Data(try key.signature(for: payload))
        signature[0] ^= 0xFF
        XCTAssertFalse(MirrorSignature.verify(payload: payload, signature: signature))
    }

    func test_verify_rejectsSignatureFromDifferentKey() throws {
        // Sign with a fresh, unrelated keypair — the verifier must reject
        // even a structurally-valid signature if it wasn't signed by the
        // pinned key. This is the core property that makes tier-walking
        // safe across untrusted mirrors.
        let imposter = Curve25519.Signing.PrivateKey()
        let payload = Data("hello mirror".utf8)
        let signature = try imposter.signature(for: payload)
        XCTAssertFalse(MirrorSignature.verify(payload: payload, signature: signature))
    }

    func test_verify_rejectsShortSignature() {
        // CryptoKit returns false (not throws) for malformed sigs — the
        // tier orchestrator's `sig.count == 64` guard runs before this, but
        // tightening the verifier's own behaviour is cheap insurance.
        let payload = Data("hello mirror".utf8)
        let shortSig = Data(count: 32)
        XCTAssertFalse(MirrorSignature.verify(payload: payload, signature: shortSig))
    }

    // MARK: - sha256Hex

    func test_sha256Hex_emptyInput() {
        // RFC 6234 known vector for SHA-256 of the empty string.
        XCTAssertEqual(
            MirrorSignature.sha256Hex(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func test_sha256Hex_knownVector() {
        // SHA-256("abc") — canonical NIST test vector.
        XCTAssertEqual(
            MirrorSignature.sha256Hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func test_sha256Hex_isLowercase() {
        // ImageHashRegistry lowercases on the read side, but uppercase
        // hex bytes from the producer would still surface as mismatches
        // against the on-the-wire bytes we hash here. Lock it down.
        let hex = MirrorSignature.sha256Hex(of: Data("abc".utf8))
        XCTAssertEqual(hex, hex.lowercased())
    }

    // MARK: - isFresh

    func test_isFresh_exactlyNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(MirrorSignature.isFresh(fetchedAt: now, now: now))
    }

    func test_isFresh_oneSecondInPast() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-1)
        XCTAssertTrue(MirrorSignature.isFresh(fetchedAt: recent, now: now))
    }

    func test_isFresh_justInsideMaxFreshnessAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 1 s shy of the 24 h cutoff — must still accept.
        let edge = now.addingTimeInterval(-(MirrorSignature.maxFreshnessAge - 1))
        XCTAssertTrue(MirrorSignature.isFresh(fetchedAt: edge, now: now))
    }

    func test_isFresh_justBeyondMaxFreshnessAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = now.addingTimeInterval(-(MirrorSignature.maxFreshnessAge + 1))
        XCTAssertFalse(MirrorSignature.isFresh(fetchedAt: stale, now: now))
    }

    func test_isFresh_futureWithinClockSkew() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 1 min into the future — within the 5-min skew tolerance.
        let near = now.addingTimeInterval(60)
        XCTAssertTrue(MirrorSignature.isFresh(fetchedAt: near, now: now))
    }

    func test_isFresh_futureBeyondClockSkew() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 10 min into the future — past the 5-min skew tolerance. A real
        // producer can't legitimately stamp future-by-10-min on a snapshot;
        // this is either broken clock or rollback-then-replay with forged
        // stamp.
        let far = now.addingTimeInterval(MirrorSignature.maxClockSkew + 60)
        XCTAssertFalse(MirrorSignature.isFresh(fetchedAt: far, now: now))
    }
}
