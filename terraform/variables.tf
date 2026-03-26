# ─────────────────────────────────────────────────────────────────────────────
# Input variables
#
# Sensitive values (api_token, account_id) should be passed via
# terraform.tfvars (which is .gitignored) or as TF_VAR_* environment variables.
# Non-sensitive defaults are set here so the tfvars file stays small.
# ─────────────────────────────────────────────────────────────────────────────

# ── Cloudflare authentication ─────────────────────────────────────────────────

variable "cloudflare_api_token" {
  description = "Cloudflare API token with permissions: R2 Read+Write, DNS Edit, Zone Read."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (visible in the dashboard sidebar URL)."
  type        = string
  sensitive   = true
}

# ── DNS zone ──────────────────────────────────────────────────────────────────

variable "zone_name" {
  description = "Root domain name managed in Cloudflare DNS (e.g. kerwan.app)."
  type        = string
  default     = "kerwan.app"
}

# ── R2 buckets ────────────────────────────────────────────────────────────────

variable "r2_releases_bucket" {
  description = "Name of the R2 bucket that stores DMG files and appcast.xml."
  type        = string
  default     = "kerwan-releases"
}

variable "r2_releases_location" {
  description = "R2 location hint.  WNAM = Western North America, ENAM = Eastern NA, WEUR = Western Europe, EEUR = Eastern Europe, APAC = Asia-Pacific."
  type        = string
  default     = "WNAM"
}

# ── Subdomains ────────────────────────────────────────────────────────────────

variable "releases_subdomain" {
  description = "Subdomain that serves DMG/appcast downloads (CNAME → R2 custom domain)."
  type        = string
  default     = "releases"
}

variable "api_subdomain" {
  description = "Subdomain for the kerwan-api backend (CNAME → Railway)."
  type        = string
  default     = "api"
}

# ── External service hostnames ────────────────────────────────────────────────

variable "railway_domain" {
  description = "Railway-generated domain for the kerwan-api service (e.g. kerwan-api.up.railway.app). Found in Railway → Settings → Networking."
  type        = string
  # No default — must be set in terraform.tfvars after first Railway deploy.
}

# ── Email (Resend) sender authentication ─────────────────────────────────────

variable "resend_dkim_record_name" {
  description = "CNAME record name provided by Resend for DKIM signing (e.g. resend._domainkey)."
  type        = string
  default     = ""
}

variable "resend_dkim_record_value" {
  description = "CNAME record value provided by Resend for DKIM signing."
  type        = string
  default     = ""
  sensitive   = false
}

variable "create_email_records" {
  description = "Set to true to create SPF + DKIM records for Resend transactional email."
  type        = bool
  default     = false
}

# ── Marketing site ────────────────────────────────────────────────────────────

variable "pages_project_name" {
  description = "Cloudflare Pages project name hosting the marketing site. Leave empty to skip Pages DNS records."
  type        = string
  default     = ""
}
