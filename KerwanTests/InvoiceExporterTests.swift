import XCTest
@testable import Kerwan

// MARK: - InvoiceExporterTests

final class InvoiceExporterTests: XCTestCase {

    // ──────────────────────────────────────────────────────────
    // MARK: - Fixtures
    // ──────────────────────────────────────────────────────────

    /// Fixed epoch used across all tests for deterministic output.
    private let base = Date(timeIntervalSince1970: 1_740_000_000) // ~Feb 2025

    private func t(_ hours: Double) -> Date {
        base.addingTimeInterval(hours * 3_600)
    }

    private func makeSession(
        id: String = UUID().uuidString,
        clientId: String? = "client-1",
        description: String? = nil,
        invoiceText: String? = nil,
        durationSecs: Int = 3_600,
        offsetHours: Double = 0
    ) -> WorkSession {
        WorkSession(
            id: id,
            clientId: clientId,
            startedAt: t(offsetHours),
            endedAt: t(offsetHours + Double(durationSecs) / 3_600),
            durationSecs: durationSecs,
            description: description,
            invoiceText: invoiceText
        )
    }

    private func makeClient(name: String = "Acme Corp", domain: String? = "acme.com") -> Client {
        Client(id: "client-1", name: name, domain: domain)
    }

    private func makeSettings(invoiceNumber: Int = 42) -> InvoiceSettings {
        InvoiceSettings(
            userName:      "Jane Smith",
            userCompany:   "Jane Smith Design",
            userAddress:   "123 Main St, San Francisco CA 94105",
            userEmail:     "jane@acme.com",
            invoiceNumber: invoiceNumber,
            hourlyRate:    150,
            paymentTerms:  "Due within 30 days",
            dateRange:     DateInterval(start: t(0), end: t(24))
        )
    }

    private let exporter = InvoiceExporter()

    // ──────────────────────────────────────────────────────────
    // MARK: - InvoiceSettings
    // ──────────────────────────────────────────────────────────

    func test_invoiceSettings_formattedInvoiceNumber() {
        // base ~= Feb 2025
        let settings = makeSettings(invoiceNumber: 42)
        let number = settings.formattedInvoiceNumber
        // Format: INV-<year>-<4-digit number>
        XCTAssertTrue(number.hasPrefix("INV-"), "Expected INV- prefix, got \(number)")
        XCTAssertTrue(number.hasSuffix("-0042"), "Expected -0042 suffix, got \(number)")
    }

    func test_invoiceSettings_formattedInvoiceNumber_paddingLeadingZeros() {
        let settings = makeSettings(invoiceNumber: 1)
        XCTAssertTrue(settings.formattedInvoiceNumber.hasSuffix("-0001"))
    }

    func test_invoiceSettings_formattedInvoiceNumber_largeNumber() {
        let settings = makeSettings(invoiceNumber: 9999)
        XCTAssertTrue(settings.formattedInvoiceNumber.hasSuffix("-9999"))
    }

    func test_invoiceSettings_defaultValues() {
        let range = DateInterval(start: base, end: t(24))
        let s = InvoiceSettings(userName: "Bob", dateRange: range)
        XCTAssertNil(s.userCompany)
        XCTAssertNil(s.userAddress)
        XCTAssertNil(s.userEmail)
        XCTAssertEqual(s.invoiceNumber, 1)
        XCTAssertEqual(s.hourlyRate, 150)
        XCTAssertEqual(s.paymentTerms, "Due within 30 days")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - PDF Export
    // ──────────────────────────────────────────────────────────

    func test_exportPDF_producesValidPDFFile() throws {
        let sessions = [makeSession()]
        let url = try exporter.exportPDF(sessions: sessions, client: makeClient(), settings: makeSettings())

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty, "PDF file should be non-empty")

        // Validate %PDF- magic bytes
        let magic = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(magic, "%PDF-", "File should start with %PDF- magic bytes")
    }

    func test_exportPDF_returnsURLWithCorrectExtension() throws {
        let url = try exporter.exportPDF(sessions: [makeSession()], client: makeClient(), settings: makeSettings())
        XCTAssertEqual(url.pathExtension, "pdf")
    }

    func test_exportPDF_filenameContainsInvoiceNumber() throws {
        let settings = makeSettings(invoiceNumber: 99)
        let url = try exporter.exportPDF(sessions: [makeSession()], client: makeClient(), settings: settings)
        XCTAssertTrue(url.lastPathComponent.contains("0099"),
                      "Filename should embed formatted invoice number")
    }

    func test_exportPDF_emptySessionsList_stillProducesValidFile() throws {
        let url = try exporter.exportPDF(sessions: [], client: makeClient(), settings: makeSettings())
        let data = try Data(contentsOf: url)
        let magic = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(magic, "%PDF-")
    }

    func test_exportPDF_multiplePages_producesValidPDF() throws {
        // 40 sessions should force at least one page break
        let sessions = (0..<40).map { i in
            makeSession(id: "s-\(i)", offsetHours: Double(i) * 2)
        }
        let url = try exporter.exportPDF(sessions: sessions, client: makeClient(), settings: makeSettings())
        let data = try Data(contentsOf: url)
        let magic = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(magic, "%PDF-")
        // A multi-page PDF will be larger than a single-page one
        XCTAssertGreaterThan(data.count, 5_000, "Multi-page PDF should be reasonably large")
    }

    func test_exportPDF_sessionWithInvoiceText_usesInvoiceText() throws {
        // Ensure no crash when invoiceText is set
        let session = makeSession(invoiceText: "Design review — 1.0 hr", durationSecs: 3600)
        let url = try exporter.exportPDF(sessions: [session], client: makeClient(), settings: makeSettings())
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
    }

    func test_exportPDF_sessionWithLongDescription_doesNotCrash() throws {
        let longDesc = String(repeating: "A", count: 200)
        let session = makeSession(description: longDesc)
        let url = try exporter.exportPDF(sessions: [session], client: makeClient(), settings: makeSettings())
        let data = try Data(contentsOf: url)
        let magic = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(magic, "%PDF-")
    }

    func test_exportPDF_clientWithNoOptionalFields() throws {
        let minimalClient = Client(id: "c2", name: "Solo Client")
        let settings = InvoiceSettings(
            userName:  "Freelancer",
            dateRange: DateInterval(start: base, end: t(48))
        )
        let url = try exporter.exportPDF(sessions: [makeSession()], client: minimalClient, settings: settings)
        let data = try Data(contentsOf: url)
        let magic = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(magic, "%PDF-")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - CSV Export
    // ──────────────────────────────────────────────────────────

    func test_exportCSV_producesFileWithBOMAndHeader() throws {
        let url = try exporter.exportCSV(sessions: [makeSession()], client: makeClient())
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""

        // BOM (check raw bytes since String(data:encoding:) may strip the BOM character)
        XCTAssertTrue(data.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]), "CSV should start with UTF-8 BOM")

        // Header row
        let header = "Date,Client,Project,Description,Hours,Rate,Amount"
        XCTAssertTrue(text.contains(header), "CSV should contain expected header")
    }

    func test_exportCSV_hasCorrectRowCount() throws {
        let sessions = (0..<5).map { i in makeSession(id: "s-\(i)", offsetHours: Double(i) * 2) }
        let url = try exporter.exportCSV(sessions: sessions, client: makeClient())
        let text = try String(contentsOf: url, encoding: .utf8)

        // Split by CRLF; filter non-empty. Count = 1 header + 5 data rows.
        let rows = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        // Strip BOM from first component count
        XCTAssertEqual(rows.count, 6, "Should have 1 header row + 5 data rows")
    }

    func test_exportCSV_usesCRLFLineEndings() throws {
        let url = try exporter.exportCSV(sessions: [makeSession()], client: makeClient())
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\r\n"), "CSV should use CRLF line endings")
    }

    func test_exportCSV_escapesCommasInDescription() throws {
        let session = makeSession(invoiceText: "Design, review, mockup")
        let url = try exporter.exportCSV(sessions: [session], client: makeClient())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"Design, review, mockup\""),
                      "Description with commas should be double-quoted")
    }

    func test_exportCSV_escapesQuotesInDescription() throws {
        let session = makeSession(invoiceText: "He said \"hello\" to me")
        let url = try exporter.exportCSV(sessions: [session], client: makeClient())
        let text = try String(contentsOf: url, encoding: .utf8)
        // RFC 4180: quotes within a quoted field are doubled
        XCTAssertTrue(text.contains("\"He said \"\"hello\"\" to me\""),
                      "Internal quotes should be doubled")
    }

    func test_exportCSV_nilClientProducesEmptyClientColumn() throws {
        let url = try exporter.exportCSV(sessions: [makeSession()], client: nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        // Data row second column should be empty: "date,,project,..."
        let dataLine = text.components(separatedBy: "\r\n").dropFirst().first ?? ""
        let cols = dataLine.components(separatedBy: ",")
        XCTAssertGreaterThanOrEqual(cols.count, 2)
        XCTAssertEqual(cols[1], "", "Client column should be empty for nil client")
    }

    func test_exportCSV_emptySessionsList_producesHeaderOnly() throws {
        let url = try exporter.exportCSV(sessions: [], client: makeClient())
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 1, "Empty sessions should produce header row only")
    }

    func test_exportCSV_hoursFormattedToTwoDecimalPlaces() throws {
        // 5400 secs = 1.5 hours
        let session = makeSession(durationSecs: 5_400)
        let url = try exporter.exportCSV(sessions: [session], client: nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("1.50"), "Duration should be formatted as 1.50")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - JSON Export
    // ──────────────────────────────────────────────────────────

    func test_exportJSON_producesValidJSONArray() throws {
        let sessions = (0..<3).map { i in makeSession(id: "s-\(i)", offsetHours: Double(i) * 2) }
        let url = try exporter.exportJSON(sessions: sessions)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        let array = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertEqual(array.count, 3)
    }

    func test_exportJSON_containsExpectedKeys() throws {
        let session = makeSession(
            description: "Sprint planning",
            invoiceText: "Sprint planning — 1.0 hr"
        )
        let url = try exporter.exportJSON(sessions: [session])
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        let array = try XCTUnwrap(json as? [[String: Any]])
        let first = try XCTUnwrap(array.first)

        let expected = ["id", "clientId", "projectId", "startedAt", "endedAt",
                        "durationSecs", "durationHours", "billableStatus",
                        "description", "invoiceText", "reviewedAt"]
        for key in expected {
            XCTAssertNotNil(first[key], "Key '\(key)' should be present in JSON output")
        }
    }

    func test_exportJSON_datesAreISO8601Strings() throws {
        let url = try exporter.exportJSON(sessions: [makeSession()])
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        let array = try XCTUnwrap(json as? [[String: Any]])
        let first = try XCTUnwrap(array.first)

        let startedAt = try XCTUnwrap(first["startedAt"] as? String)
        // ISO 8601 dates contain 'T' and 'Z' (or offset)
        XCTAssertTrue(startedAt.contains("T"),
                      "startedAt should be an ISO 8601 string, got: \(startedAt)")
    }

    func test_exportJSON_emptySessionsList_producesEmptyArray() throws {
        let url = try exporter.exportJSON(sessions: [])
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        let array = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertTrue(array.isEmpty)
    }

    func test_exportJSON_fileExtensionIsJSON() throws {
        let url = try exporter.exportJSON(sessions: [makeSession()])
        XCTAssertEqual(url.pathExtension, "json")
    }

    func test_exportJSON_sortedByStartedAt() throws {
        // Sessions intentionally out of order
        let sessions = [
            makeSession(id: "s-2", offsetHours: 4),
            makeSession(id: "s-0", offsetHours: 0),
            makeSession(id: "s-1", offsetHours: 2),
        ]
        let url = try exporter.exportJSON(sessions: sessions)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        let array = try XCTUnwrap(json as? [[String: Any]])

        // Extract IDs to verify order
        let ids = array.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["s-0", "s-1", "s-2"], "JSON output should be sorted by startedAt")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - InvoiceExportError
    // ──────────────────────────────────────────────────────────

    func test_invoiceExportError_localizedDescription_cannotCreateContext() {
        let error = InvoiceExportError.cannotCreateContext
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }

    func test_invoiceExportError_localizedDescription_writeFailure() {
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        let error = InvoiceExportError.writeFailure(url)
        XCTAssertTrue(error.errorDescription?.contains("test.pdf") ?? false,
                      "writeFailure description should include the filename")
    }
}
