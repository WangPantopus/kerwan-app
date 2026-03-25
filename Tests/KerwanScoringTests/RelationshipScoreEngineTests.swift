import XCTest
@testable import KerwanScoring
@testable import KerwanStorage

// MARK: - RelationshipScoreEngineTests

/// Unit tests for `RelationshipScoreEngine`.
///
/// All tests exercise the pure calculation methods (`recencyScore`, `frequencyScore`,
/// `promiseBonusScore`, `directionBalanceScore`, `sentimentTrendScore`, and
/// `computeComponents`) without touching a database. Database-round-trip coverage is
/// provided by `KerwanScoringIntegrationTests` (not yet written).
final class RelationshipScoreEngineTests: XCTestCase {

    // MARK: - SUT

    /// A minimal stub `StorageActor` is not needed here because all tests call
    /// the pure factor methods directly. A real engine instance is only needed
    /// for `computeComponents`, which also has no I/O.
    private var engine: RelationshipScoreEngine!

    override func setUp() async throws {
        try await super.setUp()
        // RelationshipScoreEngine requires a StorageActor; provide a temporary
        // in-memory database so setUp never throws on a CI machine.
        let storage = try StorageActor(passphrase: "test", databaseURL: inMemoryURL())
        engine = RelationshipScoreEngine(storage: storage)
    }

    override func tearDown() async throws {
        engine = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func inMemoryURL() -> URL {
        // Using a unique filename in /tmp avoids cross-test contamination while
        // keeping the path accessible for debugging.
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scoring_test_\(UUID().uuidString).db")
    }

    private let referenceDate: Date = {
        // 2024-06-15 12:00:00 UTC — a fixed "now" for all recency tests.
        var c = DateComponents()
        c.year = 2024; c.month = 6; c.day = 15; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    // MARK: - Recency score

    func test_recency_today() async {
        // 30 minutes ago → within 24 hours → 3.0 pts
        let lastSeen = referenceDate.addingTimeInterval(-1800)
        let score = await engine.recencyScore(lastSeen, now: referenceDate)
        XCTAssertEqual(score, 3.0)
    }

    func test_recency_yesterday() async {
        // ~36 hours ago → within 7 days → 2.0 pts
        let lastSeen = referenceDate.addingTimeInterval(-36 * 3600)
        let score = await engine.recencyScore(lastSeen, now: referenceDate)
        XCTAssertEqual(score, 2.0)
    }

    func test_recency_exactlyOneWeek() async {
        // 7 days ago exactly → within 7-day boundary → 2.0 pts
        let lastSeen = referenceDate.addingTimeInterval(-7 * 86400)
        let score = await engine.recencyScore(lastSeen, now: referenceDate)
        XCTAssertEqual(score, 2.0)
    }

    func test_recency_twoWeeksAgo() async {
        // 14 days ago → within 30 days → 1.0 pt
        let lastSeen = referenceDate.addingTimeInterval(-14 * 86400)
        let score = await engine.recencyScore(lastSeen, now: referenceDate)
        XCTAssertEqual(score, 1.0)
    }

    func test_recency_sixtyDaysAgo() async {
        // 60 days ago → older than 30 days → 0 pts
        let lastSeen = referenceDate.addingTimeInterval(-60 * 86400)
        let score = await engine.recencyScore(lastSeen, now: referenceDate)
        XCTAssertEqual(score, 0.0)
    }

    func test_recency_nil() async {
        // No interaction ever → 0 pts
        let score = await engine.recencyScore(nil, now: referenceDate)
        XCTAssertEqual(score, 0.0)
    }

    // MARK: - Frequency score

    func test_frequency_zero() async {
        let score = await engine.frequencyScore(0)
        XCTAssertEqual(score, 0.0)
    }

    func test_frequency_one() async {
        let score = await engine.frequencyScore(1)
        XCTAssertEqual(score, 1.0)
    }

    func test_frequency_four() async {
        let score = await engine.frequencyScore(4)
        XCTAssertEqual(score, 1.0)
    }

    func test_frequency_five() async {
        let score = await engine.frequencyScore(5)
        XCTAssertEqual(score, 1.5)
    }

    func test_frequency_ten() async {
        let score = await engine.frequencyScore(10)
        XCTAssertEqual(score, 1.5)
    }

    func test_frequency_eleven() async {
        let score = await engine.frequencyScore(11)
        XCTAssertEqual(score, 2.0)
    }

    func test_frequency_large() async {
        let score = await engine.frequencyScore(100)
        XCTAssertEqual(score, 2.0)
    }

    // MARK: - Promise bonus

    func test_promiseBonus_noOverdue() async {
        let score = await engine.promiseBonusScore(overdueCount: 0)
        XCTAssertEqual(score, 2.0)
    }

    func test_promiseBonus_oneOverdue() async {
        let score = await engine.promiseBonusScore(overdueCount: 1)
        XCTAssertEqual(score, 1.5)
    }

    func test_promiseBonus_twoOverdue() async {
        let score = await engine.promiseBonusScore(overdueCount: 2)
        XCTAssertEqual(score, 1.0)
    }

    func test_promiseBonus_fourOverdue() async {
        let score = await engine.promiseBonusScore(overdueCount: 4)
        XCTAssertEqual(score, 0.0)
    }

    func test_promiseBonus_manyOverdue_clampedAtZero() async {
        // More than 4 overdue promises → still 0 (not negative)
        let score = await engine.promiseBonusScore(overdueCount: 10)
        XCTAssertEqual(score, 0.0)
    }

    // MARK: - Direction balance

    func test_directionBalance_noInteractions() async {
        let score = await engine.directionBalanceScore(DirectionCounts(outbound: 0, inbound: 0, mutual: 0))
        XCTAssertEqual(score, 0.0)
    }

    func test_directionBalance_allMutual() async {
        // All meetings → perfectly balanced
        let score = await engine.directionBalanceScore(DirectionCounts(outbound: 0, inbound: 0, mutual: 5))
        XCTAssertEqual(score, 1.5)
    }

    func test_directionBalance_perfectlyBalanced() async {
        let score = await engine.directionBalanceScore(DirectionCounts(outbound: 5, inbound: 5, mutual: 0))
        XCTAssertEqual(score, 1.5, accuracy: 0.001)
    }

    func test_directionBalance_onlyOutbound() async {
        let score = await engine.directionBalanceScore(DirectionCounts(outbound: 5, inbound: 0, mutual: 0))
        XCTAssertEqual(score, 0.5, accuracy: 0.001)
    }

    func test_directionBalance_onlyInbound() async {
        let score = await engine.directionBalanceScore(DirectionCounts(outbound: 0, inbound: 5, mutual: 0))
        XCTAssertEqual(score, 0.5, accuracy: 0.001)
    }

    func test_directionBalance_slightlyImbalanced() async {
        // 1 inbound vs 5 outbound: ratio = 1/5 = 0.2 → score = 0.5 + 0.2 = 0.7
        let score = await engine.directionBalanceScore(DirectionCounts(outbound: 5, inbound: 1, mutual: 0))
        XCTAssertEqual(score, 0.5 + 1.0 / 5.0, accuracy: 0.001)
    }

    func test_directionBalance_mixedWithMutual() async {
        // 3 outbound + 2 mutual → effectiveOut = 3 + 1 = 4, effectiveIn = 0 + 1 = 1
        // ratio = 1/4 = 0.25 → score = 0.5 + 0.25 = 0.75
        let score = await engine.directionBalanceScore(DirectionCounts(outbound: 3, inbound: 0, mutual: 2))
        XCTAssertEqual(score, 0.5 + (1.0 / 4.0), accuracy: 0.001)
    }

    // MARK: - Sentiment trend

    func test_sentimentTrend_noData() async {
        // No interactions in any window → neutral default
        let score = await engine.sentimentTrendScore(
            recent: SentimentCounts(),
            prior:  SentimentCounts()
        )
        XCTAssertEqual(score, 1.0)
    }

    func test_sentimentTrend_recentPositiveNoPrior() async {
        // All positive recent, no prior window
        let score = await engine.sentimentTrendScore(
            recent: SentimentCounts(positive: 10, neutral: 0, negative: 0),
            prior:  SentimentCounts()
        )
        XCTAssertEqual(score, 1.5)
    }

    func test_sentimentTrend_recentNegativeNoPrior() async {
        // All negative recent, no prior window
        let score = await engine.sentimentTrendScore(
            recent: SentimentCounts(positive: 0, neutral: 0, negative: 10),
            prior:  SentimentCounts()
        )
        XCTAssertEqual(score, 0.5)
    }

    func test_sentimentTrend_recentNeutralNoPrior() async {
        // All neutral recent, no prior window → avg = 0.5 → stable
        let score = await engine.sentimentTrendScore(
            recent: SentimentCounts(positive: 0, neutral: 10, negative: 0),
            prior:  SentimentCounts()
        )
        XCTAssertEqual(score, 1.0)
    }

    func test_sentimentTrend_improving() async {
        // Prior: mostly negative (avg ≈ 0.1), recent: mostly positive (avg ≈ 0.9)
        let score = await engine.sentimentTrendScore(
            recent: SentimentCounts(positive: 9, neutral: 0, negative: 1),
            prior:  SentimentCounts(positive: 1, neutral: 0, negative: 9)
        )
        XCTAssertEqual(score, 1.5)  // delta ≈ +0.8 > 0.15
    }

    func test_sentimentTrend_declining() async {
        // Prior: mostly positive (avg ≈ 0.9), recent: mostly negative (avg ≈ 0.1)
        let score = await engine.sentimentTrendScore(
            recent: SentimentCounts(positive: 1, neutral: 0, negative: 9),
            prior:  SentimentCounts(positive: 9, neutral: 0, negative: 1)
        )
        XCTAssertEqual(score, 0.5)  // delta ≈ -0.8 < -0.15
    }

    func test_sentimentTrend_stable() async {
        // Both windows identical → delta = 0 → stable
        let counts = SentimentCounts(positive: 3, neutral: 4, negative: 3)
        let score = await engine.sentimentTrendScore(recent: counts, prior: counts)
        XCTAssertEqual(score, 1.0)
    }

    // MARK: - computeComponents (integration of all factors)

    func test_computeComponents_perfectScore() async {
        // Simulate a maximally healthy relationship
        let inputs = ContactScoreInputs(
            lastInteractionAt:   referenceDate.addingTimeInterval(-3600), // 1 hour ago → 3 pts recency
            interactionCount30d: 15,                                       // > 10 → 2 pts freq
            directionCounts30d:  DirectionCounts(outbound: 5, inbound: 5, mutual: 5),
            overduePromiseCount: 0,                                        // full 2 pts bonus
            recentSentiment:     SentimentCounts(positive: 10),
            priorSentiment:      SentimentCounts(positive: 5, neutral: 5)
        )
        let components = await engine.computeComponents(inputs: inputs, now: referenceDate)

        XCTAssertEqual(components.recency,          3.0)
        XCTAssertEqual(components.frequency,        2.0)
        XCTAssertEqual(components.promiseBonus,     2.0)
        XCTAssertEqual(components.directionBalance, 1.5, accuracy: 0.001)
        XCTAssertEqual(components.sentimentTrend,   1.5)
        XCTAssertEqual(components.total,            10.0, accuracy: 0.001)
    }

    func test_computeComponents_dormantContact() async {
        // Contact with no activity: all factors at minimum
        let inputs = ContactScoreInputs(
            lastInteractionAt:   nil,
            interactionCount30d: 0,
            directionCounts30d:  DirectionCounts(),
            overduePromiseCount: 0,    // 2 pts bonus still applies
            recentSentiment:     SentimentCounts(),
            priorSentiment:      SentimentCounts()
        )
        let components = await engine.computeComponents(inputs: inputs, now: referenceDate)

        XCTAssertEqual(components.recency,          0.0)
        XCTAssertEqual(components.frequency,        0.0)
        XCTAssertEqual(components.promiseBonus,     2.0)  // no overdue promises = full bonus
        XCTAssertEqual(components.directionBalance, 0.0)  // no interactions
        XCTAssertEqual(components.sentimentTrend,   1.0)  // no data = neutral
        XCTAssertEqual(components.total,            3.0, accuracy: 0.001)
    }

    func test_computeComponents_heavyPenalties() async {
        // Contact seen 45 days ago, low frequency, 4 overdue promises, bad sentiment
        let lastSeen = referenceDate.addingTimeInterval(-45 * 86400)
        let inputs = ContactScoreInputs(
            lastInteractionAt:   lastSeen,
            interactionCount30d: 2,
            directionCounts30d:  DirectionCounts(outbound: 8, inbound: 0, mutual: 0),
            overduePromiseCount: 4,
            recentSentiment:     SentimentCounts(positive: 0, neutral: 0, negative: 5),
            priorSentiment:      SentimentCounts(positive: 5, neutral: 0, negative: 0)
        )
        let components = await engine.computeComponents(inputs: inputs, now: referenceDate)

        XCTAssertEqual(components.recency,          0.0)   // > 30 days
        XCTAssertEqual(components.frequency,        1.0)   // 1–4 interactions
        XCTAssertEqual(components.promiseBonus,     0.0)   // 4 × 0.5 = 2.0 penalty, clamp to 0
        XCTAssertEqual(components.directionBalance, 0.5, accuracy: 0.001)  // all outbound
        XCTAssertEqual(components.sentimentTrend,   0.5)   // declining
        XCTAssertEqual(components.total,            2.0, accuracy: 0.001)
    }

    func test_computeComponents_totalClampedAboveZero() async {
        // Even with all bad factors, total should never go below 0
        let inputs = ContactScoreInputs(
            lastInteractionAt:   referenceDate.addingTimeInterval(-60 * 86400),
            interactionCount30d: 0,
            directionCounts30d:  DirectionCounts(),
            overduePromiseCount: 100,  // extreme penalty — clamps to 0
            recentSentiment:     SentimentCounts(negative: 100),
            priorSentiment:      SentimentCounts(positive: 100)
        )
        let components = await engine.computeComponents(inputs: inputs, now: referenceDate)
        XCTAssertGreaterThanOrEqual(components.total, 0.0)
    }

    func test_computeComponents_totalNeverExceedsTen() async {
        // Theoretical maximum should hit exactly 10
        let inputs = ContactScoreInputs(
            lastInteractionAt:   referenceDate.addingTimeInterval(-60),
            interactionCount30d: 20,
            directionCounts30d:  DirectionCounts(outbound: 0, inbound: 0, mutual: 20),
            overduePromiseCount: 0,
            recentSentiment:     SentimentCounts(positive: 20),
            priorSentiment:      SentimentCounts(positive: 5, neutral: 5)
        )
        let components = await engine.computeComponents(inputs: inputs, now: referenceDate)
        XCTAssertLessThanOrEqual(components.total, 10.0)
    }

    // MARK: - SentimentCounts helpers

    func test_sentimentCounts_weightedAverage_positive() {
        let counts = SentimentCounts(positive: 4, neutral: 0, negative: 0, unknown: 0)
        XCTAssertEqual(counts.weightedAverage, 1.0)
    }

    func test_sentimentCounts_weightedAverage_negative() {
        let counts = SentimentCounts(positive: 0, neutral: 0, negative: 4, unknown: 0)
        XCTAssertEqual(counts.weightedAverage, 0.0)
    }

    func test_sentimentCounts_weightedAverage_neutral() {
        let counts = SentimentCounts(positive: 0, neutral: 4, negative: 0, unknown: 0)
        XCTAssertEqual(counts.weightedAverage, 0.5)
    }

    func test_sentimentCounts_weightedAverage_mixed() {
        // 2 positive (1.0 each) + 2 negative (0.0 each) = sum 2.0, total 4 → avg 0.5
        let counts = SentimentCounts(positive: 2, neutral: 0, negative: 2, unknown: 0)
        XCTAssertEqual(counts.weightedAverage, 0.5)
    }

    func test_sentimentCounts_weightedAverage_empty() {
        XCTAssertNil(SentimentCounts().weightedAverage)
    }

    // MARK: - NightlyScoringScheduler.secondsUntilNextRun

    func test_schedulerDelay_futureToday() {
        var c = DateComponents()
        c.year = 2024; c.month = 6; c.day = 15; c.hour = 0; c.minute = 30
        let midnight = Calendar(identifier: .gregorian).date(from: c)!

        // "now" is 00:30; target is 02:00 on same day → delay ≈ 90 minutes
        let delay = NightlyScoringScheduler.secondsUntilNextRun(
            hour: 2, minute: 0,
            calendar: Calendar(identifier: .gregorian),
            from: midnight
        )
        XCTAssertEqual(delay, 90 * 60, accuracy: 1)
    }

    func test_schedulerDelay_pastToday_rollsToTomorrow() {
        var c = DateComponents()
        c.year = 2024; c.month = 6; c.day = 15; c.hour = 3; c.minute = 0
        let threeAm = Calendar(identifier: .gregorian).date(from: c)!

        // "now" is 03:00; target was 02:00 (already past) → rolls to tomorrow 02:00 ≈ 23 h
        let delay = NightlyScoringScheduler.secondsUntilNextRun(
            hour: 2, minute: 0,
            calendar: Calendar(identifier: .gregorian),
            from: threeAm
        )
        // Approximately 23 hours = 82800 seconds
        XCTAssertEqual(delay, 23 * 3600, accuracy: 60)
    }

    func test_schedulerDelay_minimumSixtySeconds() {
        // Even if "now" is exactly at target time, delay should be ≥ 60 s
        var c = DateComponents()
        c.year = 2024; c.month = 6; c.day = 15; c.hour = 2; c.minute = 0; c.second = 0
        let targetTime = Calendar(identifier: .gregorian).date(from: c)!

        let delay = NightlyScoringScheduler.secondsUntilNextRun(
            hour: 2, minute: 0,
            calendar: Calendar(identifier: .gregorian),
            from: targetTime
        )
        XCTAssertGreaterThanOrEqual(delay, 60)
    }
}
