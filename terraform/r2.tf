# ─────────────────────────────────────────────────────────────────────────────
# Cloudflare R2 — releases bucket
#
# Stores:
#   releases/Kerwan-<version>.dmg   — signed + notarized DMG
#   appcast.xml                     — Sparkle RSS feed (no-cache)
#
# Public access is enabled via:
#   1. cloudflare_r2_bucket (creates the bucket)
#   2. null_resource.r2_public_access (calls Cloudflare API to enable public
#      access — not yet a dedicated Terraform resource in cloudflare ~> 4.x)
#   3. null_resource.r2_cors (sets CORS via R2's S3-compatible API)
#   4. cloudflare_record.releases in dns.tf (CNAME releases.kerwan.app → R2)
#
# Requirements: aws CLI installed locally (pre-installed on GitHub runners)
#               and R2 credentials exported as:
#                 AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
# ─────────────────────────────────────────────────────────────────────────────

resource "cloudflare_r2_bucket" "releases" {
  account_id = var.cloudflare_account_id
  name       = var.r2_releases_bucket
  location   = var.r2_releases_location
}

# ── Public access ─────────────────────────────────────────────────────────────
# The Cloudflare Terraform provider (~> 4.x) does not yet expose an R2 public-
# access resource.  We call the Cloudflare API directly.  The provisioner runs
# only when the bucket is first created (trigger = bucket name).
#
# Requires: CLOUDFLARE_API_TOKEN environment variable (same token used by
#           the provider) OR that var.cloudflare_api_token is available.
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "r2_public_access" {
  depends_on = [cloudflare_r2_bucket.releases]

  triggers = {
    bucket_name = cloudflare_r2_bucket.releases.name
  }

  provisioner "local-exec" {
    command = <<-SHELL
      echo "▸ Enabling public access on R2 bucket: ${cloudflare_r2_bucket.releases.name}"
      curl -fsSL -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${var.cloudflare_account_id}/r2/buckets/${cloudflare_r2_bucket.releases.name}/domains/public" \
        -H "Authorization: Bearer ${var.cloudflare_api_token}" \
        -H "Content-Type: application/json" \
        -d '{"enabled": true}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('success', False):
    print('ERROR:', d.get('errors'))
    sys.exit(1)
print('Public access enabled.')
"
    SHELL
  }

  # Best-effort disable on destroy.
  provisioner "local-exec" {
    when    = destroy
    command = <<-SHELL
      curl -fsSL -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${self.triggers.bucket_name}/domains/public" \
        -H "Authorization: Bearer ${var.cloudflare_api_token}" \
        -H "Content-Type: application/json" \
        -d '{"enabled": false}' || true
    SHELL
  }
}

# ── CORS policy ───────────────────────────────────────────────────────────────
# Allows the marketing site and macOS app to read DMG/appcast URLs directly.
# Uses the R2 S3-compatible CORS API (requires R2 API credentials).
#
# Set these in your environment before running terraform apply:
#   export AWS_ACCESS_KEY_ID=<R2_ACCESS_KEY_ID>
#   export AWS_SECRET_ACCESS_KEY=<R2_SECRET_ACCESS_KEY>
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "r2_cors" {
  depends_on = [cloudflare_r2_bucket.releases]

  triggers = {
    bucket_name  = cloudflare_r2_bucket.releases.name
    cors_origins = "https://${var.zone_name}"
  }

  provisioner "local-exec" {
    command = <<-SHELL
      ENDPOINT="https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
      CORS_JSON=$(cat <<'JSON'
{
  "CORSRules": [
    {
      "AllowedOrigins": ["https://${var.zone_name}", "https://www.${var.zone_name}"],
      "AllowedMethods": ["GET", "HEAD"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag", "Content-Length", "Content-Type"],
      "MaxAgeSeconds": 3600
    }
  ]
}
JSON
)
      echo "▸ Setting CORS on bucket: ${cloudflare_r2_bucket.releases.name}"
      aws s3api put-bucket-cors \
        --bucket "${cloudflare_r2_bucket.releases.name}" \
        --endpoint-url "$ENDPOINT" \
        --region auto \
        --cors-configuration "$CORS_JSON"
      echo "▸ CORS policy applied."
    SHELL

    environment = {
      # Pick up credentials from the shell environment.
      # Do not hardcode them here.
    }
  }
}

# ── Lifecycle policy ──────────────────────────────────────────────────────────
# Old DMG files under releases/ are moved to IA storage after 180 days and
# deleted after 730 days.  appcast.xml at the root is never deleted.
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "r2_lifecycle" {
  depends_on = [cloudflare_r2_bucket.releases]

  triggers = {
    bucket_name = cloudflare_r2_bucket.releases.name
  }

  provisioner "local-exec" {
    command = <<-SHELL
      ENDPOINT="https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
      LIFECYCLE_JSON=$(cat <<'JSON'
{
  "Rules": [
    {
      "ID": "expire-old-dmgs",
      "Status": "Enabled",
      "Filter": { "Prefix": "releases/" },
      "Expiration": { "Days": 730 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 }
    }
  ]
}
JSON
)
      echo "▸ Setting lifecycle rules on: ${cloudflare_r2_bucket.releases.name}"
      aws s3api put-bucket-lifecycle-configuration \
        --bucket "${cloudflare_r2_bucket.releases.name}" \
        --endpoint-url "$ENDPOINT" \
        --region auto \
        --lifecycle-configuration "$LIFECYCLE_JSON"
      echo "▸ Lifecycle policy applied."
    SHELL
  }
}
