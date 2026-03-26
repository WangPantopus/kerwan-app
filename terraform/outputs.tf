# ─────────────────────────────────────────────────────────────────────────────
# Outputs — values needed by the release pipeline and ops runbooks
# ─────────────────────────────────────────────────────────────────────────────

# ── R2 ───────────────────────────────────────────────────────────────────────

output "r2_releases_bucket_name" {
  description = "R2 bucket name — set as R2_BUCKET in GitHub Secrets."
  value       = cloudflare_r2_bucket.releases.name
}

output "r2_releases_public_url" {
  description = "Public URL for the releases bucket (custom domain)."
  value       = "https://${var.releases_subdomain}.${var.zone_name}"
}

output "r2_releases_s3_endpoint" {
  description = "S3-compatible endpoint for the Cloudflare account — set as the endpoint-url in aws CLI calls."
  value       = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
  sensitive   = true   # Contains account ID
}

output "r2_appcast_url" {
  description = "Live appcast.xml URL — set in Sparkle's SUFeedURL Info.plist key."
  value       = "https://${var.releases_subdomain}.${var.zone_name}/appcast.xml"
}

# ── DNS ───────────────────────────────────────────────────────────────────────

output "dns_zone_id" {
  description = "Cloudflare zone ID for ${var.zone_name} — useful for adding records via the API."
  value       = data.cloudflare_zone.main.id
}

output "dns_releases_hostname" {
  description = "FQDN serving app downloads."
  value       = "${var.releases_subdomain}.${var.zone_name}"
}

output "dns_api_hostname" {
  description = "FQDN for the kerwan-api backend."
  value       = "${var.api_subdomain}.${var.zone_name}"
}

# ── GitHub Actions secrets cheatsheet ─────────────────────────────────────────
# After running `terraform apply`, copy these values into GitHub Secrets:
#
#   R2_ACCOUNT_ID       → var.cloudflare_account_id
#   R2_BUCKET           → output.r2_releases_bucket_name
#   R2_ACCESS_KEY_ID    → created manually in Cloudflare > R2 > API tokens
#   R2_SECRET_ACCESS_KEY → same source as above
#   DOWNLOAD_BASE_URL   → output.r2_releases_public_url
# ─────────────────────────────────────────────────────────────────────────────

output "github_secrets_guide" {
  description = "GitHub Actions secrets that must be set for the release pipeline."
  value = {
    R2_ACCOUNT_ID    = "(sensitive — use var.cloudflare_account_id)"
    R2_BUCKET        = cloudflare_r2_bucket.releases.name
    DOWNLOAD_BASE_URL = "https://${var.releases_subdomain}.${var.zone_name}"
  }
}
