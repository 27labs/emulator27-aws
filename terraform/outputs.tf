output "install_url" {
  description = "URL the installer is served from."
  value       = "https://${var.hostname}${var.path}"
}

output "install_command" {
  description = "Command that downloads and runs the installer."
  value       = "curl -fsSL https://${var.hostname}${var.path} | sudo bash"
}

output "distribution_id" {
  description = "CloudFront distribution that serves the installer."
  value       = aws_cloudfront_distribution.installer.id
}

output "distribution_domain_name" {
  description = "CloudFront hostname the DNS record points at."
  value       = aws_cloudfront_distribution.installer.domain_name
}

output "pricing_plan_status" {
  description = "Status of the flat-rate plan subscription, or null on pay-as-you-go."
  value       = one(awscc_pricingplanmanager_subscription.installer[*].status)
}
