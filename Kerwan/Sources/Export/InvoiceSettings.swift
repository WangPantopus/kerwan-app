import Foundation

// MARK: - InvoiceSettings

/// Configuration supplied by the caller when generating an invoice export.
///
/// `InvoiceSettings` is assembled at the call site from ``UserSettings`` fields
/// plus any per-export overrides (rate, terms, period). The exporter itself
/// does not read from any persistent store.
///
/// ```swift
/// let settings = InvoiceSettings(
///     userName:      userSettings.name ?? "Jane Smith",
///     userCompany:   "Acme Design Studio",
///     userAddress:   "123 Main St, San Francisco CA 94105",
///     userEmail:     "jane@acme.com",
///     invoiceNumber: nextInvoiceNumber,
///     hourlyRate:    userSettings.billableDefaultRate,
///     paymentTerms:  "Due within 30 days",
///     dateRange:     DateInterval(start: periodStart, end: periodEnd)
/// )
/// ```
public struct InvoiceSettings: Sendable {

    // MARK: - User identity

    /// Freelancer / company name shown in the "From:" block.
    public let userName:    String
    /// Optional company name shown below the user name.
    public let userCompany: String?
    /// Optional mailing address shown in the "From:" block.
    public let userAddress: String?
    /// Optional email shown in the "From:" block.
    public let userEmail:   String?

    // MARK: - Invoice metadata

    /// Auto-incrementing number used to generate ``formattedInvoiceNumber``.
    /// The caller is responsible for persisting the incremented value back to
    /// `user_settings` after a successful export.
    public let invoiceNumber: Int

    /// Hourly rate used for amount calculations in the PDF and CSV.
    public let hourlyRate: Double

    /// Payment terms line shown at the bottom of the PDF invoice
    /// (e.g., `"Due within 30 days"`).
    public let paymentTerms: String

    /// The billing period covered by this invoice.
    public let dateRange: DateInterval

    // MARK: - Init

    public init(
        userName:     String,
        userCompany:  String?      = nil,
        userAddress:  String?      = nil,
        userEmail:    String?      = nil,
        invoiceNumber: Int         = 1,
        hourlyRate:   Double       = 150,
        paymentTerms: String       = "Due within 30 days",
        dateRange:    DateInterval
    ) {
        self.userName     = userName
        self.userCompany  = userCompany
        self.userAddress  = userAddress
        self.userEmail    = userEmail
        self.invoiceNumber = invoiceNumber
        self.hourlyRate   = hourlyRate
        self.paymentTerms = paymentTerms
        self.dateRange    = dateRange
    }

    // MARK: - Derived

    /// Formatted invoice number, e.g. `"INV-2026-0042"`.
    ///
    /// The year is derived from the start of ``dateRange``.
    public var formattedInvoiceNumber: String {
        let year = Calendar.current.component(.year, from: dateRange.start)
        return String(format: "INV-%04d-%04d", year, invoiceNumber)
    }
}

// MARK: - InvoiceExportError

/// Errors thrown by ``InvoiceExporter``.
public enum InvoiceExportError: Error, LocalizedError {
    /// The Core Graphics PDF context could not be created.
    case cannotCreateContext
    /// Writing the exported data to the temporary file failed.
    case writeFailure(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateContext:
            return "Failed to create the PDF rendering context."
        case .writeFailure(let url):
            return "Failed to write the export file to \(url.lastPathComponent)."
        }
    }
}
