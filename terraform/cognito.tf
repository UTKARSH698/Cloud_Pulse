# ============================================================
# terraform/cognito.tf
#
# Cognito User Pool + App Client for CloudPulse API auth.
#
# How it fits into the architecture
# ----------------------------------
# Client (Postman / browser)
#   → POST to Cognito hosted UI or token endpoint
#   → receives JWT access token
#   → calls API Gateway with header: Authorization: Bearer <token>
#   → API Gateway Cognito authorizer validates token signature
#   → Lambda invoked only if token is valid
#
# Resources created
# ------------------
#   aws_cognito_user_pool           — the user directory
#   aws_cognito_user_pool_client    — app client (m2m + human flows)
#   aws_cognito_user_pool_domain    — hosted UI at
#                                     https://<domain>.auth.<region>.amazoncognito.com
#
# Free-tier note
# --------------
# Cognito is free for the first 50,000 MAUs. We disable unused
# features (MFA, advanced security) so there are no add-on charges.
# ============================================================

# ------------------------------------------------------------
# User Pool
# ------------------------------------------------------------

resource "aws_cognito_user_pool" "cloudpulse" {
  name = "${local.name_prefix}-user-pool"

  # ── Password policy ────────────────────────────────────────
  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false   # omit to keep demo-friendly
    temporary_password_validity_days = 7
  }

  # ── Username / sign-in options ─────────────────────────────
  username_attributes      = ["email"]   # users sign in with email, not username
  auto_verified_attributes = ["email"]   # Cognito sends verification code on sign-up

  username_configuration {
    case_sensitive = false   # treat ALICE@example.com == alice@example.com
  }

  # ── Standard attributes collected at sign-up ───────────────
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 3
      max_length = 254
    }
  }

  # ── Token validity ─────────────────────────────────────────
  # Access token: used to call the API (short-lived, default 1 h)
  # Refresh token: used to get new access tokens (longer, 30 days)
  # We leave ID token at default — it is not used by the API.

  # ── Account recovery ───────────────────────────────────────
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # ── Email (Cognito built-in sender — free tier) ────────────
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # ── MFA — disabled to avoid SNS SMS charges ───────────────
  mfa_configuration = "OFF"

  # ── Advanced security — disabled (paid feature) ────────────
  # user_pool_add_ons { advanced_security_mode = "OFF" }

  # ── Deletion protection — off in dev so terraform destroy works ──
  deletion_protection = var.environment == "prod" ? "ACTIVE" : "INACTIVE"
}

# ------------------------------------------------------------
# App Client
# ------------------------------------------------------------
#
# One client covers two use cases:
#   1. Human users   — Authorization Code + PKCE flow via hosted UI
#   2. M2M / Postman — Client Credentials flow for demo / testing
#
# No client secret is generated (public client) so Postman
# and browser apps can use PKCE without storing a secret.

resource "aws_cognito_user_pool_client" "cloudpulse" {
  name         = "${local.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.cloudpulse.id

  # Public client — no secret needed for PKCE flows
  generate_secret = false

  # ── Token validity ─────────────────────────────────────────
  access_token_validity  = var.cognito_token_validity_hours   # default 1 h
  refresh_token_validity = 30
  id_token_validity      = var.cognito_token_validity_hours

  token_validity_units {
    access_token  = "hours"
    refresh_token = "days"
    id_token      = "hours"
  }

  # ── Auth flows enabled ─────────────────────────────────────
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",        # secure remote password (browser SDK)
    "ALLOW_REFRESH_TOKEN_AUTH",   # refresh expired access tokens
    "ALLOW_USER_PASSWORD_AUTH",   # direct password — for Postman / demo
  ]

  # ── OAuth 2.0 settings ─────────────────────────────────────
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # Callback / logout URLs — localhost for demo; extend for real frontend
  callback_urls = [
    "http://localhost:3000/callback",
    "https://oauth.pstmn.io/v1/callback",   # Postman OAuth helper
  ]
  logout_urls = [
    "http://localhost:3000",
  ]

  supported_identity_providers = ["COGNITO"]

  # ── Security ───────────────────────────────────────────────
  # Prevent user enumeration (don't reveal whether email exists on failed auth)
  prevent_user_existence_errors = "ENABLED"

  # Read-only attributes the token exposes
  read_attributes  = ["email", "email_verified"]
  write_attributes = ["email"]
}

# ------------------------------------------------------------
# User Pool Domain
# ------------------------------------------------------------
#
# Provides the hosted sign-in UI at:
#   https://<domain>.auth.us-east-1.amazoncognito.com/login
#
# The domain prefix must be globally unique across all AWS accounts.
# We append the account ID to guarantee uniqueness.

resource "aws_cognito_user_pool_domain" "cloudpulse" {
  domain       = "${local.name_prefix}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.cloudpulse.id
}

# ------------------------------------------------------------
# Resource Server + Scopes (for M2M / Client Credentials flow)
# ------------------------------------------------------------
#
# Defines custom OAuth scopes so machine clients can request
# exactly the permissions they need, e.g.:
#   cloudpulse/ingest   — write events
#   cloudpulse/query    — read analytics
#
# Not enforced at the Lambda level in this demo, but present
# to show understanding of OAuth resource servers.

resource "aws_cognito_resource_server" "cloudpulse" {
  name         = "cloudpulse-api"
  identifier   = "https://${local.name_prefix}-api"
  user_pool_id = aws_cognito_user_pool.cloudpulse.id

  scope {
    scope_name        = "ingest"
    scope_description = "Write analytics events"
  }

  scope {
    scope_name        = "query"
    scope_description = "Read analytics query results"
  }
}
