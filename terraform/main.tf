# Serves install.sh at https://e27.samuelbido.com/aws
#
# A private S3 bucket holds the script and CloudFront serves it. DNS stays in
# the Cloudflare zone, as a CNAME to the distribution.
#
# Publish with:
#   scripts/embed.sh --check && terraform -chdir=terraform apply

# Certificates and web ACLs used by CloudFront must live in us-east-1, so
# everything does.
provider "aws" {
  region = "us-east-1"
}

provider "awscc" {
  region = "us-east-1"
}

provider "cloudflare" {
  # Reads the API token from CLOUDFLARE_API_TOKEN.
}

data "cloudflare_zone" "this" {
  filter = {
    name = var.zone_name
  }
}

# --- Storage -----------------------------------------------------------------

resource "aws_s3_bucket" "installer" {
  # Bucket names are global, so let AWS add a unique suffix.
  bucket_prefix = "${var.name}-"
}

resource "aws_s3_bucket_public_access_block" "installer" {
  bucket = aws_s3_bucket.installer.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# A change to install.sh uploads a new object. Edge caches pick it up within
# five minutes (see cache_control).
resource "aws_s3_object" "installer" {
  bucket        = aws_s3_bucket.installer.id
  key           = "install.sh"
  source        = "${path.module}/../install.sh"
  source_hash   = filemd5("${path.module}/../install.sh")
  content_type  = "text/plain; charset=utf-8"
  cache_control = "public, max-age=300"
}

# Only this distribution may read the bucket.
data "aws_iam_policy_document" "installer" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.installer.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.installer.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "installer" {
  bucket = aws_s3_bucket.installer.id
  policy = data.aws_iam_policy_document.installer.json

  depends_on = [aws_s3_bucket_public_access_block.installer]
}

# --- Certificate ---------------------------------------------------------------

# The zone's CAA records list the certificate authorities Cloudflare uses, and
# Amazon is not one of them, so ACM refuses to issue (CAA_ERROR). A CAA record
# on the hostname itself takes precedence over the zone's for this name only.
resource "cloudflare_dns_record" "caa" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = var.hostname
  type    = "CAA"
  ttl     = 300
  comment = "Lets ACM issue the certificate for ${var.hostname}"

  data = {
    flags = 0
    tag   = "issue"
    value = "amazon.com"
  }
}

resource "aws_acm_certificate" "installer" {
  domain_name       = var.hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  # ACM checks CAA when it issues, and a failed request cannot be retried.
  depends_on = [cloudflare_dns_record.caa]
}

# ACM proves ownership of the hostname through these records, and keeps using
# them to renew the certificate.
resource "cloudflare_dns_record" "certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.installer.domain_validation_options :
    option.domain_name => option
  }

  zone_id = data.cloudflare_zone.this.zone_id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 60
  proxied = false
  comment = "ACM validation for ${var.hostname}"
}

resource "aws_acm_certificate_validation" "installer" {
  certificate_arn = aws_acm_certificate.installer.arn

  depends_on = [cloudflare_dns_record.certificate_validation]
}

# --- Firewall ------------------------------------------------------------------

# The flat-rate plan requires a web ACL on the distribution. It allows
# everything except IP addresses that hammer the endpoint.
resource "aws_wafv2_web_acl" "installer" {
  name  = var.name
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = var.name
    sampled_requests_enabled   = false
  }
}

# --- Distribution --------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "installer" {
  name                              = var.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Maps /aws to the object in the bucket and answers every other path with 404.
resource "aws_cloudfront_function" "router" {
  name    = "${var.name}-router"
  runtime = "cloudfront-js-2.0"
  comment = "Routes /aws to the installer"
  publish = true
  code    = file("${path.module}/../cloudfront/router.js")
}

# The Free plan allows AWS managed policies only.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# Adds X-Content-Type-Options: nosniff, among other security headers.
data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "installer" {
  enabled         = true
  comment         = "Serves install.sh at https://${var.hostname}/aws"
  aliases         = [var.hostname]
  is_ipv6_enabled = true
  http_version    = "http2and3"
  web_acl_id      = aws_wafv2_web_acl.installer.arn

  origin {
    origin_id                = "s3"
    domain_name              = aws_s3_bucket.installer.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.installer.id
  }

  default_cache_behavior {
    target_origin_id = "s3"

    # The script is piped into a root shell, so never serve it over plain HTTP.
    viewer_protocol_policy = "redirect-to-https"

    # CloudFront answers any other method with 403.
    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.router.arn
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.installer.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# CloudFront's flat-rate Free plan: $0 a month with no overage charges, in
# place of pay-as-you-go. Changing the tier later has to be done in the
# CloudFront console; Terraform cannot change it in place.
resource "awscc_pricingplanmanager_subscription" "installer" {
  count = var.flat_rate_plan ? 1 : 0

  plan_family = "CloudFront"
  plan_tier   = "FREE"
  usage_level = "DEFAULT"

  resource_arns = [
    aws_cloudfront_distribution.installer.arn,
    aws_wafv2_web_acl.installer.arn,
  ]
}

# --- DNS -----------------------------------------------------------------------

# Not proxied: CloudFront terminates TLS with the certificate above.
resource "cloudflare_dns_record" "installer" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = var.hostname
  type    = "CNAME"
  content = aws_cloudfront_distribution.installer.domain_name
  ttl     = 300
  proxied = false
  comment = "CloudFront distribution serving the installer"
}
