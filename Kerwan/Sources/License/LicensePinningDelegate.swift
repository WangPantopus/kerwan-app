import Foundation
import CryptoKit
import os

/// A `URLSessionDelegate` that enforces TLS certificate pinning for all
/// requests sent through the ``LicenseManager``'s private URLSession.
///
/// ## Pinning strategy
///
/// SHA-256 of the DER-encoded **leaf** certificate. This is simpler than SPKI
/// pinning and sufficient for a single-backend service where the key is
/// rotated infrequently.
///
/// ## Updating pins
///
/// To compute the hash for a new certificate:
/// ```sh
/// echo | openssl s_client -connect api.kerwan.app:443 2>/dev/null \
///   | openssl x509 -outform DER \
///   | openssl dgst -sha256 -binary \
///   | base64
/// ```
/// Add the **new** hash to ``productionPinnedHashes`` **before** removing the
/// old one to allow a seamless rotation window without an app update.
///
/// ## Failure behaviour
///
/// A pin mismatch cancels the challenge via
/// `.cancelAuthenticationChallenge`. The URLSession then fails the request
/// with `URLError.cancelled`. ``LicenseManager`` catches this and treats it
/// identically to `networkUnavailable`, falling back to the 7-day cache.
///
/// ## Testing
///
/// Pass an **empty** `pinnedHashes` set in tests to disable pinning. When a
/// mock `URLProtocol` is registered on the session, authentication challenges
/// are never issued anyway, so this delegate is effectively a no-op.
final class LicensePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    // MARK: - Production pins

    /// SHA-256 hashes (base64-encoded) of trusted DER leaf certificates.
    ///
    /// Include both the active certificate and the next (backup) certificate
    /// to support zero-downtime rotation without a forced app update.
    ///
    /// > Important: Replace the placeholder values below with real hashes
    /// > before shipping. An empty set disables pinning entirely.
    static let productionPinnedHashes: Set<String> = [
        // Primary certificate — compute with the openssl command in the file header.
        // "AAAA...real_primary_hash...=",
        //
        // Backup / next certificate — pre-pin before rotation.
        // "BBBB...real_backup_hash...=",
    ]

    // MARK: - State

    private let pinnedHashes: Set<String>
    private let log = Logger(subsystem: "com.kerwan.app", category: "LicensePinning")

    // Thread-safe flag: set to true if the most recent challenge was rejected.
    // The flag is informational; ``LicenseManager`` does not read it directly —
    // it infers the failure from `URLError.cancelled`.
    private let lock = NSLock()
    private var _lastChallengeRejected = false

    /// `true` if the most recent server-trust challenge was rejected due to a
    /// hash mismatch. Resets when a challenge is accepted.
    var lastChallengeRejected: Bool {
        lock.withLock { _lastChallengeRejected }
    }

    // MARK: - Init

    /// Creates a delegate that enforces the supplied certificate hashes.
    ///
    /// - Parameter pinnedHashes: Hashes to trust. Pass an empty set to
    ///   disable pinning (development and testing only).
    init(pinnedHashes: Set<String> = productionPinnedHashes) {
        self.pinnedHashes = pinnedHashes
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only intercept server-trust challenges; defer everything else.
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Pinning disabled → accept whatever the system trusts.
        guard !pinnedHashes.isEmpty else {
            log.debug("Certificate pinning disabled — accepting default trust")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the certificate chain using the system trust store first.
        var cfError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &cfError) else {
            log.error(
                "TLS trust evaluation failed: \(cfError.debugDescription, privacy: .public)"
            )
            reject(completionHandler)
            return
        }

        // Retrieve the leaf certificate (index 0 in the evaluated chain).
        guard
            let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
            let leaf = certChain.first
        else {
            log.error("Could not extract leaf certificate from server trust")
            reject(completionHandler)
            return
        }

        // Hash the DER-encoded bytes.
        let derData = SecCertificateCopyData(leaf) as Data
        let hash = Data(SHA256.hash(data: derData)).base64EncodedString()

        if pinnedHashes.contains(hash) {
            log.debug(
                "Certificate pin matched for \(challenge.protectionSpace.host, privacy: .public)"
            )
            lock.withLock { _lastChallengeRejected = false }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            log.error(
                "Certificate pin MISMATCH — host: \(challenge.protectionSpace.host, privacy: .public) computedHash: \(hash, privacy: .public)"
            )
            reject(completionHandler)
        }
    }

    // MARK: - Private

    private func reject(
        _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        lock.withLock { _lastChallengeRejected = true }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
