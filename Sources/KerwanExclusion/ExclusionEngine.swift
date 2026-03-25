import Foundation
import KerwanStorage
import os.log

// MARK: - RawEventCandidate

/// Lightweight struct passed to ExclusionEngine before a RawEvent is written.
public struct RawEventCandidate: Sendable {
    public let sourceApp: String?
    public let windowTitle: String?
    public let url: String?
    public let emails: [String]

    public init(
        sourceApp: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        emails: [String] = []
    ) {
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.url = url
        self.emails = emails
    }
}

// MARK: - CompiledRule

/// An ExclusionRule with its regex pre-compiled (if applicable).
private struct CompiledRule {
    let rule: ExclusionRule
    let compiledRegex: NSRegularExpression? // non-nil only for .windowTitleRegex

    init(rule: ExclusionRule, log: Logger) {
        self.rule = rule
        if rule.type == .windowTitleRegex {
            do {
                compiledRegex = try NSRegularExpression(
                    pattern: rule.value,
                    options: [.caseInsensitive]
                )
            } catch {
                log.warning("ExclusionRule \(rule.id): invalid regex '\(rule.value)': \(error). Rule will be skipped.")
                compiledRegex = nil
            }
        } else {
            compiledRegex = nil
        }
    }
}

// MARK: - ExclusionEngine

/// Synchronous, stateless checker called by every capture source before writing
/// a raw event. Initialized from a snapshot of ExclusionRules; rules are
/// pre-compiled at init time so each `shouldExclude` call is pure matching.
///
/// Performance: designed to complete in <1 ms for 10–50 rules.
public struct ExclusionEngine: Sendable {

    private let rules: [CompiledRule]
    private let log = Logger(subsystem: "com.kerwan.app", category: "ExclusionEngine")

    // MARK: - Init

    public init(rules: [ExclusionRule]) {
        let logger = Logger(subsystem: "com.kerwan.app", category: "ExclusionEngine")
        self.rules = rules.map { CompiledRule(rule: $0, log: logger) }
    }

    // MARK: - Core check

    /// Returns `true` if the event should NOT be captured.
    ///
    /// Matching semantics:
    /// - `.app`: case-insensitive equality against `sourceApp`.
    /// - `.domain`: matches the eTLD+1 extracted from `url`. "bank.com" matches
    ///   "https://www.bank.com/accounts" but not "notbank.com".
    /// - `.contact`: case-insensitive match against any address in `emails`.
    /// - `.windowTitleRegex`: case-insensitive regex match against `windowTitle`.
    public func shouldExclude(_ candidate: RawEventCandidate) -> Bool {
        for compiled in rules {
            if matches(compiled, candidate: candidate) {
                return true
            }
        }
        return false
    }

    // MARK: - Rule dispatch

    private func matches(_ compiled: CompiledRule, candidate: RawEventCandidate) -> Bool {
        let rule = compiled.rule
        switch rule.type {

        case .app:
            guard let app = candidate.sourceApp else { return false }
            return app.caseInsensitiveCompare(rule.value) == .orderedSame

        case .domain:
            guard let url = candidate.url,
                  let extracted = ExclusionEngine.extractDomain(from: url) else { return false }
            // Rule value may or may not include "www."; we normalise both.
            let normalised = ExclusionEngine.normaliseDomain(rule.value)
            return extracted == normalised || extracted.hasSuffix("." + normalised)

        case .contact:
            return candidate.emails.contains { email in
                email.caseInsensitiveCompare(rule.value) == .orderedSame
            }

        case .windowTitleRegex:
            guard let regex = compiled.compiledRegex,
                  let title = candidate.windowTitle else { return false }
            let range = NSRange(title.startIndex..., in: title)
            return regex.firstMatch(in: title, options: [], range: range) != nil
        }
    }

    // MARK: - Domain helpers

    /// Extracts the host from a URL string and normalises it (lowercase, no "www.").
    static func extractDomain(from urlString: String) -> String? {
        // Prepend scheme if missing so URL can parse the host.
        let candidate = urlString.hasPrefix("http") ? urlString : "https://\(urlString)"
        guard let url = URL(string: candidate),
              let host = url.host else { return nil }
        return normaliseDomain(host)
    }

    /// Lowercases and strips a leading "www." prefix.
    static func normaliseDomain(_ domain: String) -> String {
        var d = domain.lowercased()
        if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
        return d
    }
}

// MARK: - ExclusionEngineManager

/// Actor that owns the current ExclusionEngine instance and reloads it
/// from storage whenever rules are modified.
public actor ExclusionEngineManager {

    private var engine: ExclusionEngine
    private let storage: StorageActor
    private let log = Logger(subsystem: "com.kerwan.app", category: "ExclusionEngineManager")

    public init(storage: StorageActor) async {
        self.storage = storage
        let rules = await storage.fetchExclusionRules()
        self.engine = ExclusionEngine(rules: rules)
        log.info("ExclusionEngine initialised with \(rules.count) rules.")
    }

    // MARK: - Public interface

    /// Returns `true` if the event should be excluded from capture.
    /// Non-blocking: reads the cached engine without touching storage.
    public func shouldExclude(_ candidate: RawEventCandidate) -> Bool {
        engine.shouldExclude(candidate)
    }

    /// Re-fetches all rules from storage and rebuilds the engine.
    /// Call this after `insertExclusionRule` or `deleteExclusionRule`.
    public func reloadRules() async {
        let rules = await storage.fetchExclusionRules()
        engine = ExclusionEngine(rules: rules)
        log.info("ExclusionEngine reloaded: \(rules.count) rules.")
    }

    /// Inserts a new rule, persists it, and reloads the engine atomically.
    public func addRule(_ rule: ExclusionRule) async throws {
        try await storage.insertExclusionRule(rule)
        await reloadRules()
    }

    /// Deletes a rule by id, persists the change, and reloads the engine.
    public func removeRule(id: String) async throws {
        try await storage.deleteExclusionRule(id: id)
        await reloadRules()
    }

    /// Returns a snapshot of the current rule set (for display in UI).
    public func currentRules() async -> [ExclusionRule] {
        await storage.fetchExclusionRules()
    }
}
