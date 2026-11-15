# Development

`install.sh` embeds a copy of everything in `bin/` and of the agent skill, [skill/SKILL.md](skill/SKILL.md), so the installer is a single download. After changing any of them, regenerate it:

```bash
scripts/embed.sh
```

`scripts/embed.sh --check` exits non-zero when `install.sh` is out of date.

## Hosting the installer

The installer is served at `https://e27.samuelbido.com/aws` by Amazon CloudFront, from a private S3 bucket that holds `install.sh`. A CloudFront Function ([cloudfront/router.js](cloudfront/router.js)) maps the installer path to the script and answers every other path with a 404. DNS for the hostname stays in a Cloudflare zone, as a CNAME to the distribution. All of it is managed with Terraform in [terraform/](terraform/main.tf).

To publish a new version:

```bash
scripts/embed.sh --check && terraform -chdir=terraform apply
```

A new `install.sh` reaches every edge location within five minutes, which is how long CloudFront caches it.

### Configuration and credentials

The zone and hostname are set in `terraform/terraform.tfvars`, which is not committed; [terraform/terraform.tfvars.example](terraform/terraform.tfvars.example) lists the variables. Run `terraform -chdir=terraform init` once on a fresh checkout.

Terraform needs credentials for both providers:

- AWS: the usual credential chain (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `aws login`, and so on). Everything is created in `us-east-1`, where CloudFront requires its certificate and web ACL to be.
- Cloudflare: an API token in `CLOUDFLARE_API_TOKEN` with Zone Read and DNS Edit access to the zone. The token that `wrangler login` creates cannot edit DNS records, so it does not work here.

The AWS user needs these managed policies: `AmazonS3FullAccess`, `CloudFrontFullAccess`, `AWSCertificateManagerFullAccess` and `AWSWAFFullAccess`. With the flat-rate plan enabled it also needs the Cloud Control actions `cloudformation:CreateResource`, `GetResource`, `UpdateResource`, `DeleteResource`, `ListResources` and `GetResourceRequestStatus`, which `AWSCloudFormationFullAccess` includes.

### Pricing plan

The distribution is subscribed to CloudFront's flat-rate Free plan, which costs nothing and has no overage charges. An AWS account on the Free Tier account plan is not eligible for it; set `flat_rate_plan = false` in `terraform/terraform.tfvars` to stay on pay-as-you-go. The plan tier cannot be changed through Terraform, and the distribution cannot be deleted while it is subscribed.

### State

The Terraform state is a local file, `terraform/terraform.tfstate`, which is not committed. Keep it: without it Terraform no longer knows about the deployed resources.

## Versioning

The version of `e27-aws` is `VERSION` at the top of [bin/e27-aws.sh](bin/e27-aws.sh) and follows [semantic versioning](https://semver.org). Bump it before publishing.

`e27-aws update` downloads the installer and runs it with `--update`. To try it against a local copy:

```bash
E27_AWS_INSTALL_URL="file://$PWD/install.sh" bin/e27-aws.sh update
```
