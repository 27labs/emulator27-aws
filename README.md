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

Options go before the command or the Terraform arguments:

| Option | Default | Description |
| --- | --- | --- |
| `--port PORT` | `9297` | Port the emulator listens on. |
| `--wait-time SECONDS` | `30` | How long to wait for the emulator to become ready. |
| `--idle-timeout TIME` | `45m` | The emulator exits after this long without an API call. Seconds, or a number followed by `s`, `m` or `h` (`2700`, `45m`, `2h`). |
| `--version` | | Print the `e27-aws` version. |
| `--help` | | Print the usage. |

The idle timeout can also be set with the `E27_AWS_IDLE_TIMEOUT` environment variable; `--idle-timeout` wins over it. It only applies when `e27-aws` starts the emulator, not to one that is already running.

`e27-aws --version` prints the version of `e27-aws`. For Terraform's, use `e27-aws version`.

### Teardown

```bash
e27-aws teardown
```

Shuts down the emulator on the default port (or `e27-aws --port PORT teardown`), then asks whether to also delete the Terraform state files in the current directory (`terraform.tfstate`, its backup, and those of other workspaces). The emulator keeps everything in memory, so after a teardown that state describes resources that no longer exist.

Answer the question up front with `-y` (delete) or `-n` (keep):

```bash
e27-aws teardown -y
```

### Update

```bash
e27-aws update
```

Updates AWS Emulator to its latest package and `e27-aws` to its latest version, by running the installer again. It may ask for your `sudo` password. An emulator that is already running keeps the previous version until you tear it down.

## Telemetry

The installer and `e27-aws` send anonymous usage telemetry. [TELEMETRY.md](TELEMETRY.md) lists what is sent and how to turn it off.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md).
