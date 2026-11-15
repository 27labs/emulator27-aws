---
name: e27-aws
description: Runs Terraform against a local AWS Emulator instead of real AWS, using the e27-aws command. Use when the user wants to try, test or debug a Terraform configuration for AWS locally, without an AWS account, credentials or cost, or mentions e27-aws. Not for deploying to real AWS.
---

# e27-aws

`e27-aws` is a drop-in replacement for `terraform`. It starts AWS Emulator if it is not running, points the AWS provider at it, and passes every argument to Terraform. It does not use the user's real AWS credentials.

```bash
e27-aws init
e27-aws apply -auto-approve
e27-aws destroy -auto-approve
```

- Leave the configuration as it is: do not add endpoints, credentials or CA settings to the `provider "aws"` block.
- The region is always `us-east-1`.
- Use plain `terraform` only when the user wants real AWS.
- `e27-aws` options (`--port`, `--wait-time`, `--idle-timeout`) go before the Terraform arguments; see `e27-aws --help`.

## State

The emulator keeps resources in memory. It exits after 45 minutes without an API call, and everything in it is then gone, while `terraform.tfstate` still lists it. To start clean:

```bash
e27-aws teardown -y
```

This stops the emulator and deletes the Terraform state files in the current directory. `-n` keeps them. Always pass one of the two: without them the command asks a question.

## Port

Each emulator is identified by its port: 9297 unless `--port` is given. For a separate, isolated emulator, use another one: `e27-aws --port 9298 apply`. The endpoint, the files and the log below all carry that port, so replace 9297 with the `--port` value you passed, and pass the same `--port` to `teardown`.

## Checking the result

To inspect the resources with the AWS CLI, point it at the same emulator:

```bash
p=9297 d=~/.aws/emulator/$p
AWS_ENDPOINT_URL=https://127.0.0.1:$p AWS_CA_BUNDLE=$d/ca.pem AWS_CONFIG_FILE=$d/config AWS_SHARED_CREDENTIALS_FILE=$d/emulator_credentials aws s3 ls
```

## Errors

- The emulator did not become ready: read `/tmp/aws-emulator-PORT.log` (`/tmp/aws-emulator-9297.log` by default), or retry with `--wait-time 60`.
- An API error on a resource that is valid on AWS usually means the emulator does not support that service or operation. Tell the user so; do not rewrite the configuration to get around it.
