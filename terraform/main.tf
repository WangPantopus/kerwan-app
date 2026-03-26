# ─────────────────────────────────────────────────────────────────────────────
# Kerwan Infrastructure — Terraform root module
#
# Manages:
#   • Cloudflare R2 bucket  (DMG files + appcast.xml)
#   • Cloudflare DNS records (releases., api., www., root zone)
#
# Provider  : cloudflare/cloudflare >= 4.36
# State     : Stored in a separate Cloudflare R2 bucket using the
#             S3-compatible backend.  See backend.conf.example.
#
# Bootstrap (first-time only)
# ───────────────────────────
#   1. Create the state bucket manually:
#        aws s3api create-bucket \
#          --bucket kerwan-tf-state \
#          --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
#          --region auto
#
#   2. Copy backend.conf.example → backend.conf and fill in credentials.
#
#   3. terraform init -backend-config=backend.conf
#
# Day-to-day
# ──────────
#   terraform plan  -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.36"
    }
    # null provider is used to run Cloudflare API calls (CORS, public-access)
    # that don't yet have a dedicated Terraform resource.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  # S3-compatible backend backed by Cloudflare R2.
  # Credentials come from backend.conf (not committed to git).
  # Initialize with:  terraform init -backend-config=backend.conf
  backend "s3" {
    bucket = "kerwan-tf-state"
    key    = "infra/terraform.tfstate"
    region = "auto"

    # These values are overridden by backend.conf at init time.
    # Do NOT set credentials here — keep them in backend.conf only.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}

# ─── Providers ───────────────────────────────────────────────────────────────

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
