import Foundation
import CoreGraphics
import CoreText
import AppKit

// MARK: - InvoiceExporter

/// Generates PDF, CSV, and JSON exports of confirmed work sessions.
///
/// ## Usage
///
/// ```swift
/// let exporter = InvoiceExporter()
///
/// // PDF invoice for one client:
/// let pdfURL = try exporter.exportPDF(sessions: confirmed, client: client, settings: settings)
///
/// // CSV for accounting import:
/// let csvURL = try exporter.exportCSV(sessions: confirmed, client: client)
///
/// // JSON for third-party integration:
/// let jsonURL = try exporter.exportJSON(sessions: confirmed)
///
/// // Present NSSavePanel so the user picks the final destination:
/// savePanel.nameFieldStringValue = pdfURL.lastPathComponent
/// if savePanel.runModal() == .OK, let dest = savePanel.url {
///     try FileManager.default.copyItem(at: pdfURL, to: dest)
/// }
/// ```
///
/// Every export method writes to a temporary file and returns its `URL`.
/// The caller is responsible for moving it to a user-chosen location.
public final class InvoiceExporter {

    public init() {}

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - PDF Export
    // ═══════════════════════════════════════════════════════════════════

    /// Generates a US-Letter PDF invoice and returns the temporary file URL.
    ///
    /// The PDF is drawn directly with Core Graphics + Core Text for precise
    /// layout control. Helvetica Neue is used throughout, falling back to the
    /// system font when unavailable. Additional pages are appended automatically
    /// when line items exceed one page.
    ///
    /// - Parameters:
    ///   - sessions: Work sessions to include. Sorted by `startedAt` automatically.
    ///   - client: The invoice recipient.
    ///   - settings: From-address, invoice number, rate, and period.
    /// - Returns: URL of a temporary PDF file.
    /// - Throws: ``InvoiceExportError`` on context creation or write failure.
    public func exportPDF(
        sessions: [WorkSession],
        client:   Client,
        settings: InvoiceSettings
    ) throws -> URL {
        let sorted = sessions.sorted { $0.startedAt < $1.startedAt }

        let pdfData = NSMutableData()
        var pageRect = CGRect(x: 0, y: 0, width: P.pageW, height: P.pageH)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &pageRect, nil)
        else { throw InvoiceExportError.cannotCreateContext }

        // First page ──────────────────────────────────────────────────
        ctx.beginPDFPage(nil)
        var y = drawHeader(ctx: ctx, settings: settings, client: client)
        y = drawTableHeader(ctx: ctx, y: y)

        for session in sorted {
            if y < P.bottomStop {
                ctx.endPDFPage()
                ctx.beginPDFPage(nil)
                y = drawContinuationHeader(ctx: ctx, invoiceNumber: settings.formattedInvoiceNumber)
                y = drawTableHeader(ctx: ctx, y: y)
            }
            y = drawLineItem(ctx: ctx, session: session, y: y)
        }

        // Totals block — start a fresh page if not enough room.
        if y < P.bottomStop + 100 {
            ctx.endPDFPage()
            ctx.beginPDFPage(nil)
            y = P.pageH - P.margin
        }
        y = drawTotals(ctx: ctx, sessions: sorted, settings: settings, y: y)
        drawFooter(ctx: ctx, settings: settings, y: y)

        ctx.endPDFPage()
        ctx.closePDF()

        return try writeTempFile(data: pdfData as Data,
                                 name: "\(settings.formattedInvoiceNumber).pdf")
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - CSV Export
    // ═══════════════════════════════════════════════════════════════════

    /// Generates a UTF-8-with-BOM CSV compatible with FreshBooks, QuickBooks,
    /// Wave, and Harvest time-entry import formats.
    ///
    /// Columns: `Date, Client, Project, Description, Hours, Rate, Amount`
    ///
    /// - Parameters:
    ///   - sessions: Work sessions to export (any status).
    ///   - client: Used to populate the Client column; pass `nil` for multi-client exports.
    /// - Returns: URL of a temporary CSV file.
    public func exportCSV(sessions: [WorkSession], client: Client?) throws -> URL {
        var lines: [String] = []

        // UTF-8 BOM makes Excel on Windows open the file correctly.
        let header = "\u{FEFF}Date,Client,Project,Description,Hours,Rate,Amount"
        lines.append(header)

        let clientName = client?.name ?? ""
        let sorted = sessions.sorted { $0.startedAt < $1.startedAt }

        for session in sorted {
            let date        = Self.csvDateFmt.string(from: session.startedAt)
            let project     = ""                        // caller may enrich via project lookup
            let description = (session.invoiceText ?? session.description ?? "Work session").csvEscaped
            let hours       = String(format: "%.2f", session.durationHours)
            let rate        = ""                        // unknown without settings; left for caller
            let amount      = ""

            lines.append([date, clientName.csvEscaped, project, description, hours, rate, amount]
                .joined(separator: ","))
        }

        let csv = lines.joined(separator: "\r\n") + "\r\n"
        guard let data = csv.data(using: .utf8) else {
            throw InvoiceExportError.writeFailure(URL(fileURLWithPath: "csv"))
        }
        return try writeTempFile(data: data, name: "sessions-export.csv")
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - JSON Export
    // ═══════════════════════════════════════════════════════════════════

    /// Generates a JSON file containing an array of work session objects.
    ///
    /// All fields are included. Dates are ISO 8601 strings. This format is
    /// intended for third-party integrations (e.g., Pantopus).
    ///
    /// - Parameter sessions: Work sessions to export.
    /// - Returns: URL of a temporary JSON file.
    public func exportJSON(sessions: [WorkSession]) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessions.sorted { $0.startedAt < $1.startedAt }
            .map(WorkSessionExport.init))
        return try writeTempFile(data: data, name: "sessions-export.json")
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Private: JSON wrapper
    // ═══════════════════════════════════════════════════════════════════

    private struct WorkSessionExport: Codable {
        let id:             String
        let clientId:       String?
        let projectId:      String?
        let startedAt:      Date
        let endedAt:        Date
        let durationSecs:   Int
        let durationHours:  Double
        let billableStatus: String
        let description:    String?
        let invoiceText:    String?
        let reviewedAt:     Date?

        init(_ s: WorkSession) {
            id             = s.id
            clientId       = s.clientId
            projectId      = s.projectId
            startedAt      = s.startedAt
            endedAt        = s.endedAt
            durationSecs   = s.durationSecs
            durationHours  = s.durationHours
            billableStatus = s.billableStatus.rawValue
            description    = s.description
            invoiceText    = s.invoiceText
            reviewedAt     = s.reviewedAt
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Private: Layout constants
    // ═══════════════════════════════════════════════════════════════════

    /// PDF layout constants (all values in points; 1 pt = 1/72 inch).
    private enum P {
        static let pageW:  CGFloat = 612   // 8.5 in
        static let pageH:  CGFloat = 792   // 11 in
        static let margin: CGFloat = 72    // 1 in

        static let leftX:     CGFloat = margin
        static let rightX:    CGFloat = pageW - margin    // 540
        static let topY:      CGFloat = pageH - margin    // 720
        static let bottomStop: CGFloat = margin + 90      // 162 — must stay above this

        // Table columns
        static let colDate:  CGFloat = leftX              // 72
        static let colDesc:  CGFloat = leftX + 90         // 162
        static let colHours: CGFloat = rightX             // 540 — right-aligned

        static let lineH:    CGFloat = 18
        static let sectionGap: CGFloat = 10
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Private: Fonts
    // ═══════════════════════════════════════════════════════════════════

    private enum Weight { case regular, bold }

    private func font(_ weight: Weight, _ size: CGFloat) -> NSFont {
        let name = weight == .bold ? "HelveticaNeue-Bold" : "HelveticaNeue"
        return NSFont(name: name, size: size)
            ?? (weight == .bold ? NSFont.boldSystemFont(ofSize: size)
                                : NSFont.systemFont(ofSize: size))
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Private: Drawing primitives
    // ═══════════════════════════════════════════════════════════════════

    /// Draws `text` at `(x, y)` (CGContext baseline coords) and returns the
    /// advance width of the drawn glyph run.
    @discardableResult
    private func draw(
        _ text: String,
        x: CGFloat, y: CGFloat,
        font: NSFont,
        color: NSColor = .black,
        in ctx: CGContext
    ) -> CGFloat {
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attr))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Draws `text` so its trailing edge aligns with `rightEdge`.
    private func drawRight(
        _ text: String,
        rightEdge: CGFloat, y: CGFloat,
        font: NSFont,
        color: NSColor = .black,
        in ctx: CGContext
    ) {
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attr))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: rightEdge - w, y: y)
        CTLineDraw(line, ctx)
    }

    /// Draws `text` centered within `[leftX, rightX]`.
    private func drawCenter(
        _ text: String,
        leftX: CGFloat, rightX: CGFloat, y: CGFloat,
        font: NSFont,
        in ctx: CGContext
    ) {
        let attr: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attr))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: leftX + (rightX - leftX - w) / 2, y: y)
        CTLineDraw(line, ctx)
    }

    /// Draws a horizontal rule spanning the full content width.
    private func drawRule(y: CGFloat, lineWidth: CGFloat = 0.5, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0.65, alpha: 1))
        ctx.setLineWidth(lineWidth)
        ctx.move(to: CGPoint(x: P.leftX, y: y))
        ctx.addLine(to: CGPoint(x: P.rightX, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Private: PDF sections
    // ═══════════════════════════════════════════════════════════════════

    /// Draws the invoice header (title, From/To blocks, metadata).
    /// Returns the Y position immediately below the header.
    private func drawHeader(
        ctx: CGContext,
        settings: InvoiceSettings,
        client: Client
    ) -> CGFloat {
        var y = P.topY

        // ── Title ──────────────────────────────────────────────────
        drawCenter("INVOICE", leftX: P.leftX, rightX: P.rightX, y: y,
                   font: font(.bold, 28), in: ctx)
        y -= 36

        // ── Two-column metadata block ───────────────────────────────
        // Left column: From / To  |  Right column: Invoice meta
        let rightColX: CGFloat = 340
        var yLeft  = y
        var yRight = y

        let labelF = font(.bold, 9)
        let bodyF  = font(.regular, 10)
        let metaF  = font(.regular, 10)

        // LEFT: From
        draw("FROM", x: P.leftX, y: yLeft, font: font(.bold, 8), color: .gray, in: ctx); yLeft -= 14
        draw(settings.userName, x: P.leftX, y: yLeft, font: bodyF, in: ctx);             yLeft -= 13
        if let co = settings.userCompany, !co.isEmpty {
            draw(co, x: P.leftX, y: yLeft, font: bodyF, in: ctx);                        yLeft -= 13
        }
        if let addr = settings.userAddress, !addr.isEmpty {
            draw(addr, x: P.leftX, y: yLeft, font: metaF, in: ctx);                      yLeft -= 13
        }
        if let email = settings.userEmail, !email.isEmpty {
            draw(email, x: P.leftX, y: yLeft, font: metaF, in: ctx);                     yLeft -= 13
        }
        yLeft -= 10

        // LEFT: To
        draw("BILL TO", x: P.leftX, y: yLeft, font: font(.bold, 8), color: .gray, in: ctx); yLeft -= 14
        draw(client.name, x: P.leftX, y: yLeft, font: bodyF, in: ctx);                       yLeft -= 13
        if let domain = client.domain, !domain.isEmpty {
            draw(domain, x: P.leftX, y: yLeft, font: metaF, color: .gray, in: ctx);          yLeft -= 13
        }

        // RIGHT: Invoice meta
        func meta(_ label: String, _ value: String) {
            draw(label, x: rightColX, y: yRight, font: labelF, in: ctx)
            draw(value, x: rightColX + 78, y: yRight, font: metaF, in: ctx)
            yRight -= 14
        }
        meta("INVOICE #",  settings.formattedInvoiceNumber)
        meta("DATE",       Self.displayFmt.string(from: Date()))
        meta("PERIOD",     formatPeriod(settings.dateRange))
        meta("RATE",       formatMoney(settings.hourlyRate) + "/hr")

        y = min(yLeft, yRight) - P.sectionGap
        drawRule(y: y, lineWidth: 1.0, in: ctx)
        return y - P.sectionGap
    }

    /// Draws the table column-header row. Returns Y below the second rule.
    private func drawTableHeader(ctx: CGContext, y: CGFloat) -> CGFloat {
        var y = y
        let f = font(.bold, 9)
        let labelColor = NSColor(white: 0.3, alpha: 1)

        draw("DATE",        x: P.colDate,  y: y, font: f, color: labelColor, in: ctx)
        draw("DESCRIPTION", x: P.colDesc,  y: y, font: f, color: labelColor, in: ctx)
        drawRight("HOURS",  rightEdge: P.colHours, y: y, font: f, color: labelColor, in: ctx)
        y -= 4
        drawRule(y: y, in: ctx)
        return y - P.lineH + 2
    }

    /// Draws a single line-item row. Returns Y below the drawn row.
    private func drawLineItem(ctx: CGContext, session: WorkSession, y: CGFloat) -> CGFloat {
        let dateStr  = Self.lineItemDateFmt.string(from: session.startedAt)
        let descStr  = session.invoiceText ?? session.description ?? "Work session"
        let hoursStr = String(format: "%.1f", session.durationHours)

        let bodyF = font(.regular, 10)
        draw(dateStr,  x: P.colDate, y: y, font: bodyF, in: ctx)

        // Truncate description to fit in column (approx. 48 chars before overflow).
        let truncDesc = descStr.count > 52 ? String(descStr.prefix(49)) + "…" : descStr
        draw(truncDesc, x: P.colDesc, y: y, font: bodyF, in: ctx)
        drawRight(hoursStr, rightEdge: P.colHours, y: y, font: bodyF, in: ctx)

        return y - P.lineH
    }

    /// Draws the totals section (subtotal, rate, total). Returns Y below footer.
    private func drawTotals(
        ctx: CGContext,
        sessions: [WorkSession],
        settings: InvoiceSettings,
        y: CGFloat
    ) -> CGFloat {
        var y = y + 4   // small lift above any preceding rule

        drawRule(y: y, lineWidth: 1.0, in: ctx)
        y -= P.lineH

        let totalHours  = sessions.reduce(0.0) { $0 + $1.durationHours }
        let totalAmount = totalHours * settings.hourlyRate

        let labelF      = font(.bold,    10)
        let valueF      = font(.regular, 10)
        let totalLabelF = font(.bold,    13)
        let totalValueF = font(.bold,    13)
        let subLabelX:  CGFloat = P.rightX - 200

        func totalsRow(_ label: String, _ value: String, lf: NSFont = labelF, vf: NSFont = valueF) {
            draw(label, x: subLabelX, y: y, font: lf, in: ctx)
            drawRight(value, rightEdge: P.rightX, y: y, font: vf, in: ctx)
        }

        totalsRow("Subtotal:", "\(String(format: "%.1f", totalHours)) hrs")
        y -= P.lineH
        totalsRow("Rate:", formatMoney(settings.hourlyRate) + "/hr")
        y -= P.lineH + 4
        drawRule(y: y, in: ctx); y -= P.lineH + 2
        totalsRow("TOTAL:", formatMoney(totalAmount), lf: totalLabelF, vf: totalValueF)
        y -= P.lineH + 6
        drawRule(y: y, lineWidth: 1.0, in: ctx)

        return y - P.sectionGap
    }

    /// Draws the payment terms and thank-you footer.
    private func drawFooter(ctx: CGContext, settings: InvoiceSettings, y: CGFloat) {
        var y = y
        let noteF = font(.regular, 9)
        let grayC = NSColor(white: 0.45, alpha: 1)
        draw(settings.paymentTerms, x: P.leftX, y: y, font: noteF, color: grayC, in: ctx)
        y -= 14
        draw("Thank you for your business!", x: P.leftX, y: y, font: noteF, color: grayC, in: ctx)
    }

    /// Draws a compact header for continuation pages. Returns starting Y for content.
    private func drawContinuationHeader(ctx: CGContext, invoiceNumber: String) -> CGFloat {
        let y = P.topY
        draw(invoiceNumber + " (continued)",
             x: P.leftX, y: y,
             font: font(.bold, 11),
             color: NSColor(white: 0.4, alpha: 1),
             in: ctx)
        drawRule(y: y - 6, lineWidth: 1.0, in: ctx)
        return y - P.lineH - 4
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Private: Helpers
    // ═══════════════════════════════════════════════════════════════════

    private func formatPeriod(_ interval: DateInterval) -> String {
        let start = Self.displayFmt.string(from: interval.start)
        let end   = Self.displayFmt.string(from: interval.end)
        return "\(start) – \(end)"
    }

    private func formatMoney(_ amount: Double) -> String {
        Self.moneyFmt.string(from: NSNumber(value: amount))
            ?? String(format: "$%.2f", amount)
    }

    private func writeTempFile(data: Data, name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw InvoiceExportError.writeFailure(url)
        }
        return url
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Private: Formatters (static, thread-safe after init)
    // ═══════════════════════════════════════════════════════════════════

    /// "Mar 3" — used for line items.
    private static let lineItemDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// "March 22, 2026" — used in header and period.
    private static let displayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// "2024-03-22" — ISO date for CSV rows.
    private static let csvDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// US dollar currency formatter.
    private static let moneyFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle       = .currency
        f.currencyCode      = "USD"
        f.locale            = Locale(identifier: "en_US")
        return f
    }()
}

// MARK: - String + CSV escaping

private extension String {
    /// Returns the string quoted for CSV if it contains commas, quotes, or newlines.
    var csvEscaped: String {
        guard self.contains(",") || self.contains("\"") || self.contains("\n") else {
            return self
        }
        return "\"" + self.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
