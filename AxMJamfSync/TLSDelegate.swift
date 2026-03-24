// TLSDelegate.swift
// URLSessionDelegate for TLS server trust validation.
// Evaluates the server certificate chain against the macOS system trust store,
// rejecting self-signed certs, expired certs, and custom root CAs (MITM proxies).
// This is stricter than default URLSession behaviour but is NOT certificate pinning
// (pinning would check against a specific known cert/key, not the system store).
// Applied to all URLSessions (ABM device, ABM coverage, Jamf, token endpoints).

import Foundation
import Security

final class TLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            // Non-TLS challenge (e.g. basic auth) — defer to default handling
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the server's certificate chain against the system trust store.
        // This rejects:
        //   - Self-signed certificates
        //   - Expired certificates
        //   - Certificates with mismatched hostnames
        //   - Certificates from untrusted / custom root CAs (i.e. MITM proxies)
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(serverTrust, &error)

        if trusted {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            let host   = challenge.protectionSpace.host
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
            Task {
                await LogService.shared.warn("[TLS] Certificate validation FAILED for \(host): \(reason) — connection rejected.")
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
