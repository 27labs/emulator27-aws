# Development

`install.sh` embeds a copy of everything in `bin/`, so the installer is a single download. After changing a file in `bin/`, regenerate it:

```bash
scripts/embed.sh
```

`scripts/embed.sh --check` exits non-zero when `install.sh` is out of date.

The installer is served at `https://e27.samuelbido.com/aws` by Amazon CloudFront, from a private S3 bucket that holds `install.sh`. A CloudFront Function ([cloudfront/router.js](cloudfront/router.js)) maps `/aws` to the script and answers every other path with a 404. DNS for the hostname stays in the Cloudflare zone, as a CNAME to the distribution. All of it is managed with Terraform in [terraform/](terraform/main.tf). To publish a new version:

```bash
scripts/embed.sh --check && terraform -chdir=terraform apply
```

A new `install.sh` reaches every edge location within five minutes, which is how long CloudFront caches it.

Terraform needs credentials for both providers. Run `terraform -chdir=terraform init` once on a fresh checkout.

- AWS: the usual credential chain (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, and so on), with access to S3, CloudFront, ACM, AWS WAF and Pricing Plan Manager. Everything is created in `us-east-1`.
- Cloudflare: an API token in `CLOUDFLARE_API_TOKEN` with DNS edit access to your zone.

The distribution is subscribed to CloudFront's flat-rate Free plan, which costs nothing and has no overage charges. An AWS account on the Free Tier account plan is not eligible for it; set `flat_rate_plan = false` in `terraform/terraform.tfvars` to stay on pay-as-you-go. The plan tier cannot be changed through Terraform, and the distribution cannot be deleted while it is subscribed.

The Terraform state is a local file, `terraform/terraform.tfstate`, which is not committed. Keep it: without it Terraform no longer knows about the deployed resources.

The version of `e27-aws` is `VERSION` at the top of [bin/e27-aws.sh](bin/e27-aws.sh) and follows [semantic versioning](https://semver.org). Bump it before publishing.

`e27-aws update` downloads the installer and runs it with `--update`. To try it against a local copy:

```bash
E27_AWS_INSTALL_URL="file://$PWD/install.sh" bin/e27-aws.sh update
```
