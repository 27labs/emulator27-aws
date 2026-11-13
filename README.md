# emulator27-aws
Auto start the AWS Emulator when using standard Terraform configuration files.

## Install

```bash
curl -fsSL https://e27.samuelbido.com/aws | sudo bash
```

The installer:

1. Installs [AWS Emulator](https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-linux.html) and [Terraform](https://developer.hashicorp.com/terraform/install) if they are missing, using their official packages. This is the only step that needs `sudo`.
2. Installs `e27-aws.sh` into your own `~/.local/bin` (not root's) and links it as `e27-aws`.

Supported platforms: Debian, Ubuntu, Fedora and Arch Linux (and their derivatives), on x86_64 and aarch64.

On Arch Linux, AWS provides no AWS Emulator package, so the installer stops if `aws-emulator` is not already on your `PATH`. Terraform is installed with `pacman`.

If `~/.local/bin` is not on your `PATH`, add it to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

Use `e27-aws` wherever you would use `terraform`. It starts the emulator if it isn't already running and points Terraform's AWS provider at it:

```bash
e27-aws init
```

```bash
e27-aws apply
```

Options go before the Terraform arguments:

| Option | Default | Description |
| --- | --- | --- |
| `--port PORT` | `9297` | Port the emulator listens on. |
| `--timeout SECONDS` | `30` | How long to wait for the emulator to become ready. |

## Development

`install.sh` embeds a copy of everything in `bin/`, so the installer is a single download. After changing a file in `bin/`, regenerate it:

```bash
scripts/embed.sh
```

`scripts/embed.sh --check` exits non-zero when `install.sh` is out of date.
