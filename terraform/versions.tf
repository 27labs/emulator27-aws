terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Only for the CloudFront flat-rate plan subscription, which the aws
    # provider does not have.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.100"
    }
    # DNS for the hostname stays in the Cloudflare zone.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
