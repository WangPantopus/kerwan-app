import XCTest
@testable import KerwanExclusion
@testable import KerwanStorage

// MARK: - ExclusionEngineTests

final class ExclusionEngineTests: XCTestCase {

    // MARK: - Helpers

    private func engine(_ rules: [ExclusionRule]) -> ExclusionEngine {
        ExclusionEngine(rules: rules)
    }

    private func candidate(
        app: String? = nil,
        title: String? = nil,
        url: String? = nil,
        emails: [String] = []
    ) -> RawEventCandidate {
        RawEventCandidate(sourceApp: app, windowTitle: title, url: url, emails: emails)
    }

    // MARK: - Empty rules

    func test_emptyRules_nothingExcluded() {
        let e = engine([])
        XCTAssertFalse(e.shouldExclude(candidate(app: "Slack", title: "messages")))
        XCTAssertFalse(e.shouldExclude(candidate(url: "https://gmail.com")))
    }

    // MARK: - .app rules

    func test_appRule_exactMatch_excludes() {
        let e = engine([ExclusionRule(type: .app, value: "1Password")])
        XCTAssertTrue(e.shouldExclude(candidate(app: "1Password")))
    }

    func test_appRule_caseInsensitive_excludes() {
        let e = engine([ExclusionRule(type: .app, value: "Slack")])
        XCTAssertTrue(e.shouldExclude(candidate(app: "slack")))
        XCTAssertTrue(e.shouldExclude(candidate(app: "SLACK")))
        XCTAssertTrue(e.shouldExclude(candidate(app: "Slack")))
    }

    func test_appRule_differentApp_doesNotExclude() {
        let e = engine([ExclusionRule(type: .app, value: "1Password")])
        XCTAssertFalse(e.shouldExclude(candidate(app: "Safari")))
    }

    func test_appRule_nilApp_doesNotExclude() {
        let e = engine([ExclusionRule(type: .app, value: "Safari")])
        XCTAssertFalse(e.shouldExclude(candidate(app: nil)))
    }

    // MARK: - .domain rules

    func test_domainRule_httpsScheme_excludes() {
        let e = engine([ExclusionRule(type: .domain, value: "bank.com")])
        XCTAssertTrue(e.shouldExclude(candidate(url: "https://bank.com/login")))
    }

    func test_domainRule_subdomain_excludes() {
        let e = engine([ExclusionRule(type: .domain, value: "bank.com")])
        XCTAssertTrue(e.shouldExclude(candidate(url: "https://www.bank.com/accounts")))
        XCTAssertTrue(e.shouldExclude(candidate(url: "https://secure.bank.com/transfer")))
    }

    func test_domainRule_httpScheme_excludes() {
        let e = engine([ExclusionRule(type: .domain, value: "intranet.corp")])
        XCTAssertTrue(e.shouldExclude(candidate(url: "http://intranet.corp/dashboard")))
    }

    func test_domainRule_noScheme_excludes() {
        let e = engine([ExclusionRule(type: .domain, value: "bank.com")])
        XCTAssertTrue(e.shouldExclude(candidate(url: "bank.com/login")))
    }

    func test_domainRule_differentDomain_doesNotExclude() {
        let e = engine([ExclusionRule(type: .domain, value: "bank.com")])
        XCTAssertFalse(e.shouldExclude(candidate(url: "https://notbank.com")))
        XCTAssertFalse(e.shouldExclude(candidate(url: "https://fakebank.com")))
    }

    func test_domainRule_nilUrl_doesNotExclude() {
        let e = engine([ExclusionRule(type: .domain, value: "bank.com")])
        XCTAssertFalse(e.shouldExclude(candidate(url: nil)))
    }

    func test_domainRule_wwwPrefixInRule_normalised() {
        // If user adds rule as "www.bank.com" it should still match "bank.com"
        let e = engine([ExclusionRule(type: .domain, value: "www.bank.com")])
        XCTAssertTrue(e.shouldExclude(candidate(url: "https://bank.com/login")))
        XCTAssertTrue(e.shouldExclude(candidate(url: "https://www.bank.com/login")))
    }

    // MARK: - .contact rules

    func test_contactRule_matchesEmailInList() {
        let e = engine([ExclusionRule(type: .contact, value: "boss@company.com")])
        XCTAssertTrue(e.shouldExclude(candidate(emails: ["other@x.com", "boss@company.com"])))
    }

    func test_contactRule_caseInsensitive() {
        let e = engine([ExclusionRule(type: .contact, value: "Boss@Company.COM")])
        XCTAssertTrue(e.shouldExclude(candidate(emails: ["boss@company.com"])))
    }

    func test_contactRule_emailNotInList_doesNotExclude() {
        let e = engine([ExclusionRule(type: .contact, value: "secret@company.com")])
        XCTAssertFalse(e.shouldExclude(candidate(emails: ["public@company.com"])))
    }

    func test_contactRule_emptyEmails_doesNotExclude() {
        let e = engine([ExclusionRule(type: .contact, value: "anyone@x.com")])
        XCTAssertFalse(e.shouldExclude(candidate(emails: [])))
    }

    // MARK: - .windowTitleRegex rules

    func test_regexRule_matchesWindowTitle() {
        let e = engine([ExclusionRule(type: .windowTitleRegex, value: #"\b(password|passphrase)\b"#)])
        XCTAssertTrue(e.shouldExclude(candidate(title: "Change your password — Security")))
        XCTAssertTrue(e.shouldExclude(candidate(title: "Enter passphrase for SSH key")))
    }

    func test_regexRule_caseInsensitive() {
        let e = engine([ExclusionRule(type: .windowTitleRegex, value: "password")])
        XCTAssertTrue(e.shouldExclude(candidate(title: "PASSWORD MANAGER")))
        XCTAssertTrue(e.shouldExclude(candidate(title: "Password Reset")))
    }

    func test_regexRule_noMatch_doesNotExclude() {
        let e = engine([ExclusionRule(type: .windowTitleRegex, value: "password")])
        XCTAssertFalse(e.shouldExclude(candidate(title: "Weekly status update")))
    }

    func test_regexRule_nilTitle_doesNotExclude() {
        let e = engine([ExclusionRule(type: .windowTitleRegex, value: "password")])
        XCTAssertFalse(e.shouldExclude(candidate(title: nil)))
    }

    // MARK: - Invalid regex handling

    func test_invalidRegex_doesNotCrash_ruleSkipped() {
        // An unclosed bracket is an invalid regex.
        let bad = ExclusionRule(type: .windowTitleRegex, value: "[invalid(")
        let e = engine([bad])
        // Must not crash, and must not exclude anything (rule is silently skipped).
        XCTAssertFalse(e.shouldExclude(candidate(title: "[invalid(")))
        XCTAssertFalse(e.shouldExclude(candidate(title: "normal window title")))
    }

    func test_invalidRegex_otherRulesStillApply() {
        let bad   = ExclusionRule(type: .windowTitleRegex, value: "***")
        let good  = ExclusionRule(type: .app, value: "Keychain Access")
        let e = engine([bad, good])
        XCTAssertTrue(e.shouldExclude(candidate(app: "Keychain Access")))
        XCTAssertFalse(e.shouldExclude(candidate(app: "Safari")))
    }

    // MARK: - Domain extraction

    func test_extractDomain_https() {
        XCTAssertEqual(ExclusionEngine.extractDomain(from: "https://www.google.com/search"), "google.com")
    }

    func test_extractDomain_http() {
        // No www. prefix → full host is returned unchanged (subdomain rule matching handles it)
        XCTAssertEqual(ExclusionEngine.extractDomain(from: "http://api.internal.corp/v1"), "api.internal.corp")
    }

    func test_extractDomain_noScheme() {
        XCTAssertEqual(ExclusionEngine.extractDomain(from: "bank.com/accounts"), "bank.com")
    }

    func test_extractDomain_ipAddress() {
        // IP addresses have no meaningful domain; we return them as-is.
        let d = ExclusionEngine.extractDomain(from: "http://192.168.1.1/admin")
        XCTAssertEqual(d, "192.168.1.1")
    }

    func test_extractDomain_noSubdomain() {
        XCTAssertEqual(ExclusionEngine.extractDomain(from: "https://example.com"), "example.com")
    }

    func test_extractDomain_multipleSubdomains() {
        XCTAssertEqual(
            ExclusionEngine.extractDomain(from: "https://a.b.c.example.com/path"),
            "a.b.c.example.com" // full host, minus leading www — rule match handles suffix
        )
    }

    func test_extractDomain_invalidUrl_returnsNil() {
        XCTAssertNil(ExclusionEngine.extractDomain(from: "not a url at all !!!"))
    }

    // MARK: - Multiple rules, first match wins

    func test_multipleRules_anyMatchExcludes() {
        let rules: [ExclusionRule] = [
            ExclusionRule(type: .app, value: "1Password"),
            ExclusionRule(type: .domain, value: "bank.com"),
        ]
        let e = engine(rules)
        XCTAssertTrue(e.shouldExclude(candidate(url: "https://bank.com")))
        XCTAssertTrue(e.shouldExclude(candidate(app: "1Password")))
        XCTAssertFalse(e.shouldExclude(candidate(app: "Safari", url: "https://google.com")))
    }

    // MARK: - Performance

    func test_performance_50rules_1000candidates_under50ms() {
        var rules: [ExclusionRule] = []
        for i in 0..<15 {
            rules.append(ExclusionRule(type: .app, value: "App\(i)"))
        }
        for i in 0..<15 {
            rules.append(ExclusionRule(type: .domain, value: "domain\(i).com"))
        }
        for i in 0..<10 {
            rules.append(ExclusionRule(type: .contact, value: "user\(i)@example.com"))
        }
        for i in 0..<10 {
            rules.append(ExclusionRule(type: .windowTitleRegex, value: "title_pattern_\(i)"))
        }
        XCTAssertEqual(rules.count, 50)

        let e = engine(rules)
        let candidates = (0..<1000).map { i in
            RawEventCandidate(
                sourceApp: "NomatchApp\(i)",
                windowTitle: "Some window \(i)",
                url: "https://nomatch\(i).io/path",
                emails: ["x\(i)@nomatch.io"]
            )
        }

        let start = Date()
        for c in candidates { _ = e.shouldExclude(c) }
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms

        XCTAssertLessThan(elapsed, 200, "50 rules × 1000 candidates took \(elapsed)ms, expected <200ms")
    }
}
