# ─────────────────────────────────────────────────────────────────────────────
# Cloudflare DNS records for kerwan.app
#
# Record map
# ──────────────────────────────────────────────────────────────────────────────
# releases.kerwan.app  CNAME → R2 bucket custom domain  (proxied)
# api.kerwan.app       CNAME → Railway generated domain  (proxied)
# www.kerwan.app       CNAME → kerwan.app / Pages        (proxied)
# kerwan.app           → Cloudflare Pages (if configured) or placeholder
#
# SPF + DKIM records are created when var.create_email_records = true.
# ─────────────────────────────────────────────────────────────────────────────

# ── Zone lookup ───────────────────────────────────────────────────────────────

data "cloudflare_zone" "main" {
  name = var.zone_name
}

# ── releases.kerwan.app → R2 custom domain ───────────────────────────────────
# The CNAME points to the R2 bucket's Cloudflare-managed endpoint.
# Cloudflare proxies this so the origin IP (R2) is never exposed and WAF,
# caching, and the custom TLS cert are all provided automatically.
#
# After `terraform apply`, also register the custom domain in R2:
#   Dashboard → R2 → kerwan-releases → Settings → Custom Domains → Add Domain
#   Enter: releases.kerwan.app
# (or run the null_resource.r2_public_access provisioner which calls the API)
# ─────────────────────────────────────────────────────────────────────────────
resource "cloudflare_record" "releases" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.releases_subdomain
  type    = "CNAME"
  # R2 public-access endpoint format: <bucket>.<account_id>.r2.cloudflarestorage.com
  content = "${var.r2_releases_bucket}.${var.cloudflare_account_id}.r2.cloudflarestorage.com"
  proxied = true
  ttl     = 1   # Must be 1 (auto) when proxied = true

  comment = "Managed by Terraform — DMG + appcast CDN (Cloudflare R2)"
}

# ── api.kerwan.app → Railway ──────────────────────────────────────────────────
# Railway provisions a TLS cert automatically when the custom domain is added
# in Railway → Settings → Networking → Custom Domains.
# ─────────────────────────────────────────────────────────────────────────────
resource "cloudflare_record" "api" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.api_subdomain
  type    = "CNAME"
  content = var.railway_domain
  proxied = true
  ttl     = 1

  comment = "Managed by Terraform — kerwan-api backend (Railway)"
}

# ── www.kerwan.app → root (redirect) ─────────────────────────────────────────
# Cloudflare Page Rules / Redirect Rules handle the actual 301.  This CNAME
# just ensures www resolves through Cloudflare's proxy.
# ─────────────────────────────────────────────────────────────────────────────
resource "cloudflare_record" "www" {
  zone_id = data.cloudflare_zone.main.id
  name    = "www"
  type    = "CNAME"
  content = var.zone_name
  proxied = true
  ttl     = 1

  comment = "Managed by Terraform — www redirect"
}

# ── Cloudflare Pages (marketing site) ────────────────────────────────────────
# Created only when var.pages_project_name is set.
# Pages automatically adds the zone apex record; we only need the CNAME for
# the custom domain in the Pages project settings.
# ─────────────────────────────────────────────────────────────────────────────
resource "cloudflare_record" "pages_custom_domain" {
  count = var.pages_project_name != "" ? 1 : 0

  zone_id = data.cloudflare_zone.main.id
  name    = var.zone_name   # Zone apex — @
  type    = "CNAME"
  content = "${var.pages_project_name}.pages.dev"
  proxied = true
  ttl     = 1

  comment = "Managed by Terraform — Cloudflare Pages (marketing site)"
}

# ── SPF record ───────────────────────────────────────────────────────────────
# Authorises Resend's sending IPs.  Created when var.create_email_records = true.
# ─────────────────────────────────────────────────────────────────────────────
resource "cloudflare_record" "spf" {
  count = var.create_email_records ? 1 : 0

  zone_id = data.cloudflare_zone.main.id
  name    = var.zone_name
  type    = "TXT"
  content = "\"v=spf1 include:amazonses.com ~all\""
  proxied = false
  ttl     = 3600

  comment = "Managed by Terraform — SPF for Resend transactional email"
}

# ── DKIM record ───────────────────────────────────────────────────────────────
# CNAME provided by Resend.  Copy the values from your Resend dashboard:
#   Domain Settings → DKIM
# ─────────────────────────────────────────────────────────────────────────────
resource "cloudflare_record" "dkim" {
  count = var.create_email_records && var.resend_dkim_record_name != "" ? 1 : 0

  zone_id = data.cloudflare_zone.main.id
  name    = var.resend_dkim_record_name
  type    = "CNAME"
  content = var.resend_dkim_record_value
  proxied = false
  ttl     = 3600

  comment = "Managed by Terraform — DKIM for Resend transactional email"
}

# ── DMARC record ──────────────────────────────────────────────────────────────
# Minimal DMARC policy: monitor only (p=none) with Resend's default reporting.
# Upgrade to p=quarantine or p=reject once SPF/DKIM are confirmed working.
# ─────────────────────────────────────────────────────────────────────────────
resource "cloudflare_record" "dmarc" {
  count = var.create_email_records ? 1 : 0

  zone_id = data.cloudflare_zone.main.id
  name    = "_dmarc"
  type    = "TXT"
  content = "\"v=DMARC1; p=none; rua=mailto:dmarc@${var.zone_name}; ruf=mailto:dmarc@${var.zone_name}; fo=1\""
  proxied = false
  ttl     = 3600

  comment = "Managed by Terraform — DMARC policy"
}
