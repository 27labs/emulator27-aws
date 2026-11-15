# Set these in terraform.tfvars; see terraform.tfvars.example.

variable "zone_name" {
  description = "Cloudflare zone the hostname belongs to, for example \"example.com\"."
  type        = string
}

variable "hostname" {
  description = "Hostname the installer is served from, for example \"get.example.com\". Must be inside the zone."
  type        = string

  validation {
    condition     = var.hostname == var.zone_name || endswith(var.hostname, ".${var.zone_name}")
    error_message = "The hostname must be the zone itself or a name inside it."
  }
}

variable "path" {
  description = "URL path the installer is served at. Every other path returns 404."
  type        = string
  default     = "/aws"

  validation {
    condition     = can(regex("^(/[A-Za-z0-9._~-]+)+$", var.path))
    error_message = "The path must start with \"/\", must not end with \"/\", and may only contain letters, digits, \".\", \"_\", \"~\" and \"-\" between slashes."
  }
}

variable "name" {
  description = "Name given to the AWS resources, and the prefix of the bucket name."
  type        = string
  default     = "e27-installer"
}

variable "flat_rate_plan" {
  description = "Subscribe the distribution to CloudFront's flat-rate Free plan ($0, no overage charges). Set to false to stay on pay-as-you-go, for example when the account is on the AWS Free Tier account plan, which is not eligible."
  type        = bool
  default     = true
}

variable "rate_limit" {
  description = "Requests one IP address may make in 5 minutes before AWS WAF blocks it."
  type        = number
  default     = 100

  validation {
    condition     = var.rate_limit >= 10
    error_message = "AWS WAF does not accept a rate limit below 10."
  }
}
