import Foundation
import os

/// Resolves incoming names and email addresses to existing ``Contact`` records,
/// creating new contacts when no suitable match exists.
///
/// ## Resolution Algorithm
///
/// Each call to ``resolve(names:emails:source:timestamp:)`` runs a four-step
/// cascade. The first step that produces a confident match short-circuits the
/// remaining steps:
///
/// 1. **Exact email match** — look up every supplied email in `ContactIdentity`
///    and in `Contact.emailPrimary`. Confidence: 1.0.
/// 2. **Domain + name similarity ≥ `domainNameThreshold`** — for emails with a
///    known domain, find contacts whose email domain matches and whose display
///    name has Levenshtein similarity ≥ threshold against any supplied name.
///    Single match → confidence 0.85; multiple matches → confidence 0.6 + `needsReview`.
/// 3. **Name-only similarity ≥ `nameOnlyThreshold` + temporal proximity** — search
///    all contacts for a high-similarity name. If there is exactly one candidate
///    *and* it has a recent interaction within `proximityWindowSecs`, return it
///    at confidence 0.7.
/// 4. **Create new contact** — no match found; create a new ``Contact`` with
///    `needsReview = true`. Confidence: 0.5.
///
/// ## Merge and Split
///
/// ``mergeContacts(sourceId:targetId:)`` moves all interactions, promises, and
/// identities from the source contact onto the target, then deletes the source.
/// ``splitContact(contactId:identityIds:)`` moves the specified identities into a
/// brand-new contact and returns it.
///
/// Both operations append a ``CorrectionLog`` entry so the adaptive threshold
/// system can learn from user corrections.
public actor IdentityResolver {

    // MARK: - Configuration

    /// Levenshtein similarity threshold for Step 2 (domain + name match).
    /// Defaults to 0.8. Adjusted over time by ``adjustThresholds(basedOnCorrections:)``.
    public var domainNameThreshold: Double = 0.8

    /// Levenshtein similarity threshold for Step 3 (name-only match).
    /// Defaults to 0.9. Adjusted over time by ``adjustThresholds(basedOnCorrections:)``.
    public var nameOnlyThreshold: Double = 0.9

    /// Seconds each side of `timestamp` that count as "temporal proximity" in Step 3.
    /// Defaults to 7 days (604 800 seconds).
    public var proximityWindowSecs: Double = 3_600 * 24 * 7

    // MARK: - Dependencies

    private let storage: any IdentityResolverStorage
    private let logger = Logger(subsystem: "com.kerwan.app", category: "IdentityResolver")

    // MARK: - Init

    public init(storage: any IdentityResolverStorage) {
        self.storage = storage
    }

    // MARK: - Core Resolution

    /// Resolves a set of names and emails to a single ``Contact``.
    ///
    /// - Parameters:
    ///   - names: Display names observed in the source (may be empty).
    ///   - emails: Email addresses observed in the source (may be empty).
    ///   - source: The platform channel where the identity was seen.
    ///   - timestamp: When the observation occurred (used for temporal proximity).
    /// - Returns: A ``ResolvedIdentity`` describing the matched or newly-created contact.
    public func resolve(
        names: [String],
        emails: [String],
        source: IdentitySource,
        timestamp: Date
    ) async throws -> ResolvedIdentity {
        let normEmails = emails
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let normNames = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Step 1: exact email match.
        if let result = try await stepExactEmail(emails: normEmails, source: source) {
            return result
        }

        // Step 2: domain + name similarity.
        if let result = try await stepDomainName(emails: normEmails, names: normNames, source: source) {
            return result
        }

        // Step 3: name-only + temporal proximity.
        if let result = try await stepNameOnly(names: normNames, source: source, timestamp: timestamp) {
            return result
        }

        // Step 4: create new contact.
        return try await stepCreateNew(names: normNames, emails: normEmails, source: source)
    }

    // MARK: - Merge

    /// Merges `sourceId` into `targetId`, reassigning all related records.
    ///
    /// After the merge the source contact is deleted. A ``CorrectionLog`` entry
    /// with action `.merge` is written for threshold adaptation.
    ///
    /// - Parameters:
    ///   - sourceId: The contact to absorb (will be deleted).
    ///   - targetId: The surviving contact.
    public func mergeContacts(sourceId: EntityID, targetId: EntityID) async throws {
        // Move interactions and promises to the target contact.
        try await storage.reassignInteractions(from: sourceId, to: targetId)
        try await storage.reassignPromises(from: sourceId, to: targetId)

        // Re-link all identities from source to target.
        let identities = try await storage.findIdentities(forContactId: sourceId)
        for identity in identities {
            let moved = ContactIdentity(
                id:          identity.id,
                contactId:   targetId,
                source:      identity.source,
                identifier:  identity.identifier,
                displayName: identity.displayName,
                confidence:  identity.confidence
            )
            try await storage.upsertIdentity(moved)
        }

        // Delete source contact (cascades to any remaining identity rows).
        try await storage.deleteContact(id: sourceId)

        // Record the correction for adaptive threshold learning.
        let log = CorrectionLog(
            action:          .merge,
            sourceContactId: sourceId,
            targetContactId: targetId
        )
        try await storage.insertCorrectionLog(log)

        logger.info("Merged contact \(sourceId, privacy: .public) → \(targetId, privacy: .public)")
    }

    // MARK: - Split

    /// Splits `identityIds` from `contactId` into a new contact.
    ///
    /// The specified ``ContactIdentity`` records are re-linked to a freshly-created
    /// ``Contact``. A ``CorrectionLog`` entry with action `.split` is written.
    ///
    /// - Parameters:
    ///   - contactId: The contact to split identities away from.
    ///   - identityIds: The ``ContactIdentity/id`` values to move to the new contact.
    /// - Returns: The newly created ``Contact``.
    @discardableResult
    public func splitContact(
        contactId: EntityID,
        identityIds: [String]
    ) async throws -> Contact {
        let identitySet = Set(identityIds)
        let all = try await storage.findIdentities(forContactId: contactId)
        let toMove = all.filter { identitySet.contains($0.id) }

        // Infer a display name from the identities being split off.
        let displayName = toMove.compactMap(\.displayName).first ?? "Unknown"
        let newContact = Contact(displayName: displayName, needsReview: true)
        try await storage.upsertContact(newContact)

        // Re-link the split identities to the new contact.
        for identity in toMove {
            let moved = ContactIdentity(
                id:          identity.id,
                contactId:   newContact.id,
                source:      identity.source,
                identifier:  identity.identifier,
                displayName: identity.displayName,
                confidence:  identity.confidence
            )
            try await storage.upsertIdentity(moved)
        }

        // Encode split identity IDs into the log details blob.
        let detailsJSON = (try? String(
            data: JSONEncoder().encode(identityIds),
            encoding: .utf8
        )) ?? "[]"

        let log = CorrectionLog(
            action:          .split,
            sourceContactId: contactId,
            targetContactId: newContact.id,
            detailsJSON:     detailsJSON
        )
        try await storage.insertCorrectionLog(log)

        logger.info(
            "Split \(identityIds.count) identities from \(contactId, privacy: .public) → \(newContact.id, privacy: .public)"
        )
        return newContact
    }

    // MARK: - Adaptive Thresholds

    /// Analyses past corrections and adjusts resolution thresholds accordingly.
    ///
    /// This is a placeholder for future machine-learned threshold adaptation.
    /// Current heuristic:
    /// - If the merge error rate (splits ÷ merges) exceeds 20 %, tighten both
    ///   thresholds by 0.02 (the resolver has been too aggressive).
    /// - If the error rate is under 5 % *and* there are more than 10 confirmed
    ///   merges, relax the domain+name threshold by 0.01 (the resolver is too
    ///   conservative).
    ///
    /// Thresholds are clamped to `[0.60, 0.99]`.
    public func adjustThresholds(basedOnCorrections corrections: [CorrectionLog]) async {
        let merges = corrections.filter { $0.action == .merge }.count
        let splits = corrections.filter { $0.action == .split }.count

        guard merges > 0 else { return }

        let errorRate = Double(splits) / Double(merges)

        if errorRate > 0.20 {
            domainNameThreshold = min(0.99, domainNameThreshold + 0.02)
            nameOnlyThreshold   = min(0.99, nameOnlyThreshold   + 0.02)
            logger.info(
                "Thresholds tightened — domain: \(self.domainNameThreshold), name: \(self.nameOnlyThreshold)"
            )
        } else if errorRate < 0.05 && merges > 10 {
            domainNameThreshold = max(0.60, domainNameThreshold - 0.01)
            logger.info("Domain threshold relaxed: \(self.domainNameThreshold)")
        }
    }

    // MARK: - Private: Step 1 — Exact email

    private func stepExactEmail(
        emails: [String],
        source: IdentitySource
    ) async throws -> ResolvedIdentity? {
        for email in emails {
            // Check ContactIdentity records first.
            let identities = try await storage.findIdentities(byEmail: email)
            if let first = identities.first {
                try await ensureIdentity(
                    contactId:  first.contactId,
                    source:     source,
                    identifier: email,
                    confidence: 1.0
                )
                return ResolvedIdentity(
                    contactId:   first.contactId,
                    clientId:    nil,
                    confidence:  1.0,
                    isNew:       false,
                    needsReview: false
                )
            }

            // Fall through to Contact.emailPrimary.
            if let contact = try await storage.findContact(byEmail: email) {
                try await ensureIdentity(
                    contactId:  contact.id,
                    source:     source,
                    identifier: email,
                    confidence: 1.0
                )
                return ResolvedIdentity(
                    contactId:   contact.id,
                    clientId:    nil,
                    confidence:  1.0,
                    isNew:       false,
                    needsReview: false
                )
            }
        }
        return nil
    }

    // MARK: - Private: Step 2 — Domain + name

    private func stepDomainName(
        emails: [String],
        names: [String],
        source: IdentitySource
    ) async throws -> ResolvedIdentity? {
        guard !names.isEmpty else { return nil }

        let domains = emails.compactMap { emailDomain($0) }
        guard !domains.isEmpty else { return nil }

        // Check if any domain maps to a known client.
        let clients = try await storage.listClients()
        let matchedClientId = clients.first { client in
            guard let d = client.domain else { return false }
            return domains.contains(d.lowercased())
        }?.id

        // Collect contacts whose email domain matches and whose name is similar.
        var seen = Set<EntityID>()
        var ranked: [(contact: Contact, similarity: Double)] = []

        for name in names {
            let candidates = try await storage.findContacts(byNormalisedName: name.lowercased())
            for contact in candidates {
                guard !seen.contains(contact.id) else { continue }
                guard let primary = contact.emailPrimary,
                      let contactDomain = emailDomain(primary),
                      domains.contains(contactDomain) else { continue }

                let sim = LevenshteinDistance.similarity(name, contact.displayName)
                guard sim >= domainNameThreshold else { continue }

                seen.insert(contact.id)
                ranked.append((contact, sim))
            }
        }

        guard !ranked.isEmpty else { return nil }

        if ranked.count == 1 {
            let match = ranked[0].contact
            try await ensureIdentity(
                contactId:  match.id,
                source:     source,
                identifier: names.first ?? match.displayName,
                confidence: 0.85
            )
            return ResolvedIdentity(
                contactId:   match.id,
                clientId:    matchedClientId,
                confidence:  0.85,
                isNew:       false,
                needsReview: false
            )
        } else {
            // Multiple candidates — pick best by similarity, flag for review.
            let best = ranked.max(by: { $0.similarity < $1.similarity })!.contact
            try await ensureIdentity(
                contactId:  best.id,
                source:     source,
                identifier: names.first ?? best.displayName,
                confidence: 0.6
            )
            return ResolvedIdentity(
                contactId:   best.id,
                clientId:    matchedClientId,
                confidence:  0.6,
                isNew:       false,
                needsReview: true
            )
        }
    }

    // MARK: - Private: Step 3 — Name only + temporal proximity

    private func stepNameOnly(
        names: [String],
        source: IdentitySource,
        timestamp: Date
    ) async throws -> ResolvedIdentity? {
        guard !names.isEmpty else { return nil }

        var candidates: [(contact: Contact, similarity: Double)] = []

        for name in names {
            let found = try await storage.findContacts(byNormalisedName: name.lowercased())
            for contact in found {
                let sim = LevenshteinDistance.similarity(name, contact.displayName)
                guard sim >= nameOnlyThreshold else { continue }
                if !candidates.contains(where: { $0.contact.id == contact.id }) {
                    candidates.append((contact, sim))
                }
            }
        }

        // Only proceed when exactly one candidate exists.
        guard candidates.count == 1 else { return nil }

        let candidate = candidates[0].contact
        let hasProximity = try await storage.contactHasInteraction(
            contactId:     candidate.id,
            near:          timestamp,
            windowSeconds: proximityWindowSecs
        )
        guard hasProximity else { return nil }

        try await ensureIdentity(
            contactId:  candidate.id,
            source:     source,
            identifier: names.first ?? candidate.displayName,
            confidence: 0.7
        )
        return ResolvedIdentity(
            contactId:   candidate.id,
            clientId:    nil,
            confidence:  0.7,
            isNew:       false,
            needsReview: false
        )
    }

    // MARK: - Private: Step 4 — Create new

    private func stepCreateNew(
        names: [String],
        emails: [String],
        source: IdentitySource
    ) async throws -> ResolvedIdentity {
        let displayName = names.first ?? emails.first ?? "Unknown"
        let contact = Contact(
            displayName:  displayName,
            emailPrimary: emails.first,
            needsReview:  true
        )
        try await storage.upsertContact(contact)

        let identifier = emails.first ?? displayName
        try await ensureIdentity(
            contactId:  contact.id,
            source:     source,
            identifier: identifier,
            confidence: 0.5
        )

        logger.info(
            "Created new contact \(contact.id, privacy: .public) '\(displayName, privacy: .public)'"
        )
        return ResolvedIdentity(
            contactId:   contact.id,
            clientId:    nil,
            confidence:  0.5,
            isNew:       true,
            needsReview: true
        )
    }

    // MARK: - Private: Helpers

    /// Upserts a ``ContactIdentity`` only when none already exists with the same
    /// contactId + source + identifier triple.
    private func ensureIdentity(
        contactId: EntityID,
        source: IdentitySource,
        identifier: String,
        confidence: Double
    ) async throws {
        let existing = try await storage.findIdentities(forContactId: contactId)
        guard !existing.contains(where: { $0.source == source && $0.identifier == identifier }) else {
            return
        }
        let identity = ContactIdentity(
            contactId:   contactId,
            source:      source,
            identifier:  identifier,
            displayName: nil,
            confidence:  confidence
        )
        try await storage.upsertIdentity(identity)
    }

    /// Extracts the lowercased domain portion of an email address (the part after `@`).
    private func emailDomain(_ email: String) -> String? {
        guard let atIdx = email.lastIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: atIdx)...]).lowercased()
        return domain.isEmpty ? nil : domain
    }
}

// MARK: - ResolvedIdentity

/// The outcome of a single identity resolution attempt.
public struct ResolvedIdentity: Sendable {
    /// The resolved or newly-created ``Contact/id``. `nil` only on internal error.
    public let contactId: EntityID?

    /// The matched ``Client/id``, if the email domain matched a known client.
    /// `nil` when no client domain match was found or when resolution used
    /// the name-only or new-contact paths.
    public let clientId: EntityID?

    /// The resolver's confidence that this is the correct contact (0.0–1.0).
    public let confidence: Double

    /// `true` when a new ``Contact`` was created during this resolution.
    public let isNew: Bool

    /// `true` when the resolution is ambiguous and warrants user confirmation.
    public let needsReview: Bool

    public init(
        contactId: EntityID?,
        clientId: EntityID?,
        confidence: Double,
        isNew: Bool,
        needsReview: Bool
    ) {
        self.contactId   = contactId
        self.clientId    = clientId
        self.confidence  = max(0.0, min(1.0, confidence))
        self.isNew       = isNew
        self.needsReview = needsReview
    }
}
