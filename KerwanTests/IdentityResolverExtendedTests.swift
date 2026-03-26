import XCTest
@testable import Kerwan

// MARK: - Test-only helpers for IdentityResolver actor property mutation

private extension IdentityResolver {
    func setDomainNameThreshold(_ value: Double) { domainNameThreshold = value }
    func setNameOnlyThreshold(_ value: Double)   { nameOnlyThreshold   = value }
}

/// Extended tests for ``IdentityResolver`` covering scenarios not present in
/// ``IdentityResolverTests``.
///
/// The mock storage (`MockIdentityStorage`) and most happy-path flows are
/// already exercised exhaustively in that file. This suite focuses on:
///  - Multiple-email resolution order
///  - Empty-input edge cases (both arrays empty, whitespace-only names)
///  - `adjustThresholds` minimum-clamp guard (0.60)
///  - `splitContact` with non-matching identity IDs
///  - Email whitespace normalisation
final class IdentityResolverExtendedTests: XCTestCase {

    // MARK: - Helpers

    private func makeStorage() -> MockIdentityStorage { MockIdentityStorage() }

    private func makeContact(name: String, email: String? = nil) -> Contact {
        var c = Contact(displayName: name)
        c.emailPrimary = email
        return c
    }

    private func makeMergeLog(n: Int) -> [CorrectionLog] {
        (0..<n).map { _ in CorrectionLog(action: .merge) }
    }

    private func makeSplitLog(n: Int) -> [CorrectionLog] {
        (0..<n).map { _ in CorrectionLog(action: .split) }
    }

    // MARK: - Multiple-email resolution order

    /// When two emails are supplied and only the SECOND appears in storage, the
    /// resolver should still find the match via step 1.
    func test_resolve_multipleEmails_secondEmailMatches_returnsExistingContact() async throws {
        let storage = makeStorage()
        let contact = makeContact(name: "Bob Brown", email: "bob@corp.com")
        try await storage.upsertContact(contact)
        let identity = ContactIdentity(
            contactId:  contact.id,
            source:     .email,
            identifier: "bob@corp.com"
        )
        try await storage.upsertIdentity(identity)

        let resolver = IdentityResolver(storage: storage)
        let result = try await resolver.resolve(
            names:     ["Bob"],
            emails:    ["unknown@other.com", "bob@corp.com"],
            source:    .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.contactId, contact.id,
                       "Second email match should be found via step 1")
        XCTAssertFalse(result.isNew)
        XCTAssertEqual(result.confidence, 1.0)
    }

    // MARK: - Empty names and emails

    /// Both arrays empty → the resolver falls through all four steps and creates
    /// a new contact (step 4). The new contact should be marked `needsReview`.
    func test_resolve_emptyNamesAndEmails_createsNewContact() async throws {
        let storage  = makeStorage()
        let resolver = IdentityResolver(storage: storage)

        let result = try await resolver.resolve(
            names:     [],
            emails:    [],
            source:    .zoom,
            timestamp: Date()
        )

        XCTAssertTrue(result.isNew, "No match possible → must create new contact")
        XCTAssertTrue(result.needsReview)

        let contacts = await Array(storage.contacts.values)
        XCTAssertEqual(contacts.count, 1, "Exactly one new contact should be created")
    }

    /// Whitespace-only names are stripped and treated as empty → resolver reaches
    /// step 4 with no usable name input.
    func test_resolve_whitespaceOnlyNames_treatedAsEmpty_createsNew() async throws {
        let storage  = makeStorage()
        let resolver = IdentityResolver(storage: storage)

        let result = try await resolver.resolve(
            names:     ["   ", "\t"],
            emails:    [],
            source:    .zoom,
            timestamp: Date()
        )

        XCTAssertTrue(result.isNew)
    }

    /// An email supplied with leading and trailing whitespace must be trimmed and
    /// matched to the stored lowercase version.
    func test_resolve_emailWithWhitespace_normalisedAndMatched() async throws {
        let storage = makeStorage()
        let contact = makeContact(name: "Alice Whitespace", email: "alice@example.com")
        try await storage.upsertContact(contact)
        let identity = ContactIdentity(
            contactId:  contact.id,
            source:     .email,
            identifier: "alice@example.com"
        )
        try await storage.upsertIdentity(identity)

        let resolver = IdentityResolver(storage: storage)
        let result = try await resolver.resolve(
            names:     ["Alice"],
            emails:    ["  alice@example.com  "],   // surrounding whitespace
            source:    .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.contactId, contact.id,
                       "Whitespace-padded email must be trimmed and matched")
        XCTAssertFalse(result.isNew)
    }

    // MARK: - Names-only resolution (no email supplied)

    /// When no email is provided the resolver skips steps 1 and 2 and tries step
    /// 3 (name-only + temporal proximity). A stored contact with a matching name
    /// and a recent interaction should be returned with confidence 0.7.
    func test_resolve_namesOnly_noEmail_matchesViaStep3() async throws {
        let storage = makeStorage()
        let contact = makeContact(name: "Carlos Rivera")
        try await storage.upsertContact(contact)

        // Seed an interaction so the temporal-proximity check passes.
        let now = Date()
        let interaction = Interaction(
            contactId:       contact.id,
            source:          .audio,
            interactionType: .meeting,
            startedAt:       now.addingTimeInterval(-3_600),  // 1 hour ago
            endedAt:         now
        )
        await storage.seedInteraction(interaction)

        let resolver = IdentityResolver(storage: storage)
        let result = try await resolver.resolve(
            names:     ["Carlos Rivera"],
            emails:    [],
            source:    .zoom,
            timestamp: now
        )

        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertFalse(result.isNew)
        XCTAssertEqual(result.confidence, 0.7, accuracy: 0.001)
    }

    // MARK: - adjustThresholds: minimum clamp

    /// `domainNameThreshold` cannot be relaxed below 0.60.
    func test_adjustThresholds_domainThreshold_clampsAtMin() async throws {
        let storage  = makeStorage()
        let resolver = IdentityResolver(storage: storage)

        // Set threshold just above the minimum so the relax rule fires.
        await resolver.setDomainNameThreshold(0.61)

        // Build a corrections list that triggers relaxation:
        // error rate (splits / merges) < 0.05 and merges > 10.
        let corrections = makeMergeLog(n: 15)  // 15 merges, 0 splits → rate = 0

        // First call: 0.61 − 0.01 = 0.60
        await resolver.adjustThresholds(basedOnCorrections: corrections)
        let threshold1 = await resolver.domainNameThreshold
        XCTAssertGreaterThanOrEqual(threshold1, 0.60)

        // Subsequent calls must not push below 0.60.
        for _ in 0..<10 {
            await resolver.adjustThresholds(basedOnCorrections: corrections)
        }
        let finalThreshold = await resolver.domainNameThreshold
        XCTAssertEqual(finalThreshold, 0.60, accuracy: 0.001,
                       "domainNameThreshold must never drop below 0.60")
    }

    /// `nameOnlyThreshold` cannot be tightened above 0.99.
    func test_adjustThresholds_nameOnlyThreshold_clampsAtMax() async throws {
        let storage  = makeStorage()
        let resolver = IdentityResolver(storage: storage)
        await resolver.setNameOnlyThreshold(0.98)

        // High error rate triggers tightening.
        let corrections = makeMergeLog(n: 5) + makeSplitLog(n: 5) // rate = 1.0 > 0.20

        await resolver.adjustThresholds(basedOnCorrections: corrections)
        let threshold1 = await resolver.nameOnlyThreshold
        XCTAssertEqual(threshold1, 1.0.nextDown, accuracy: 0.011,
                       "After tighten: 0.98 + 0.02 = 1.00 clamped to 0.99")

        // Further calls must not push past 0.99.
        for _ in 0..<10 {
            await resolver.adjustThresholds(basedOnCorrections: corrections)
        }
        let finalThreshold = await resolver.nameOnlyThreshold
        XCTAssertLessThanOrEqual(finalThreshold, 0.99)
    }

    /// `adjustThresholds` with only split logs (no merges) is a no-op because
    /// the algorithm requires `merges > 0` to compute the error rate.
    func test_adjustThresholds_onlySplits_noOp() async throws {
        let storage  = makeStorage()
        let resolver = IdentityResolver(storage: storage)
        let before   = await resolver.domainNameThreshold

        let corrections = makeSplitLog(n: 10)
        await resolver.adjustThresholds(basedOnCorrections: corrections)

        let after = await resolver.domainNameThreshold
        XCTAssertEqual(after, before, accuracy: 0.001)
    }

    // MARK: - splitContact with unrecognised identity IDs

    /// If the supplied `identityIds` don't match any stored identity for that
    /// contact, `splitContact` still creates a new contact (with "Unknown" name)
    /// and writes a correction log.
    func test_splitContact_unknownIdentityIds_createsEmptyContact() async throws {
        let storage = makeStorage()
        let contact = makeContact(name: "Dana Original")
        try await storage.upsertContact(contact)

        let resolver  = IdentityResolver(storage: storage)
        let newContact = try await resolver.splitContact(
            contactId:   contact.id,
            identityIds: ["non-existent-id"]
        )

        XCTAssertEqual(newContact.displayName, "Unknown",
                       "No matching identities → display name defaults to 'Unknown'")
        XCTAssertTrue(newContact.needsReview)

        let logs = await storage.logs
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].action, .split)
    }

    // MARK: - Resolve is idempotent for exact email

    /// Calling `resolve` twice for the same email address must not duplicate the
    /// `ContactIdentity` record.
    func test_resolve_exactEmail_calledTwice_noIdentityDuplication() async throws {
        let storage = makeStorage()
        let contact = makeContact(name: "Eve Idempotent", email: "eve@dup.com")
        try await storage.upsertContact(contact)

        let identity = ContactIdentity(
            contactId:  contact.id,
            source:     .email,
            identifier: "eve@dup.com",
            confidence: 1.0
        )
        try await storage.upsertIdentity(identity)

        let resolver = IdentityResolver(storage: storage)

        let r1 = try await resolver.resolve(
            names: ["Eve"], emails: ["eve@dup.com"],
            source: .calendar, timestamp: Date()
        )
        let r2 = try await resolver.resolve(
            names: ["Eve"], emails: ["eve@dup.com"],
            source: .calendar, timestamp: Date()
        )

        XCTAssertEqual(r1.contactId, r2.contactId)
        XCTAssertFalse(r1.isNew)
        XCTAssertFalse(r2.isNew)
        // At most 2 identity records (original + possibly 1 calendar identity).
        let identities = await Array(storage.identities.values)
            .filter { $0.contactId == contact.id }
        XCTAssertLessThanOrEqual(identities.count, 2,
                                 "Repeated resolve must not keep adding identity rows")
    }
}
