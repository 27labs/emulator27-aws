# Telemetry

Two separate things send usage data. Both are on by default and each has its own switch.

## e27-aws

The installer and `e27-aws` send anonymous usage events to [PostHog](https://posthog.com), to show which platforms and commands matter and where things fail:

| Event | Sent when | Details |
| --- | --- | --- |
| `install_started`, `install_completed`, `install_failed` | The installer runs | Distribution ID and family, whether it is an update, whether it ran through `sudo`, which dependencies it installed, and the step that failed. |
| `command_run` | `e27-aws` runs Terraform | The Terraform subcommand (`plan`, `apply`, ...; anything unrecognised is `other`), whether the emulator was started or already running, how long it took to start, whether `--port` differs from the default, and the idle timeout in seconds with where it was set (`--idle-timeout`, `E27_AWS_IDLE_TIMEOUT` or the default). |
| `emulator_start_failed` | The emulator did not become ready | The wait time. |
| `teardown` | `e27-aws teardown` runs | Whether an emulator was stopped, and whether the state files were deleted, kept or absent. |
| `update` | `e27-aws update` finishes | The new version. |
| `remove` | `e27-aws remove` runs | Nothing more. It also deletes the random ID. |

Every event also carries the CPU architecture, the `e27-aws` version (except the installer's events), whether `CI` is set, and a random ID kept in `~/.config/e27-aws/id`. Nothing else is sent: no paths, file names, Terraform arguments or options, user or host names, or error messages. As with any HTTP request, PostHog sees the IP address the event comes from.

Turn it off with:

```bash
export E27_AWS_TELEMETRY=off
```

`DO_NOT_TRACK=1` works too.

## AWS Emulator

AWS Emulator collects its own usage telemetry for AWS. `e27-aws` neither sees it nor changes it: it starts the emulator with the emulator's default, which is on. Turn it off with the emulator's own variable:

```bash
export EMULATOR_TELEMETRY=off
```

It only takes effect the next time `e27-aws` starts an emulator; run `e27-aws teardown` first if one is running. The emulator's config file works too.
