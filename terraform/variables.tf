variable "zone_name" {
  description = "Cloudflare zone the hostname belongs to."
  type        = string
  default     = "samuelbido.com"
}

variable "hostname" {
  description = "Hostname the installer is served from."
  type        = string
  default     = "e27.samuelbido.com"
}

variable "name" {
  description = "Name given to the AWS resources."
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
}
