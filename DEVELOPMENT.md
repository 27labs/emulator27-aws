# Development

`install.sh` embeds a copy of everything in `bin/`, so the installer is a single download. After changing a file in `bin/`, regenerate it:

```bash
scripts/embed.sh
```

`scripts/embed.sh --check` exits non-zero when `install.sh` is out of date.

The installer is served at `https://e27.samuelbido.com/aws` by a Cloudflare Worker ([worker/index.js](worker/index.js)) that bundles `install.sh`. To publish a new version:

```bash
scripts/embed.sh --check && wrangler deploy
```

The version of `e27-aws` is `VERSION` at the top of [bin/e27-aws.sh](bin/e27-aws.sh) and follows [semantic versioning](https://semver.org). Bump it before publishing.

`e27-aws update` downloads the installer and runs it with `--update`. To try it against a local copy:

```bash
E27_AWS_INSTALL_URL="file://$PWD/install.sh" bin/e27-aws.sh update
```
