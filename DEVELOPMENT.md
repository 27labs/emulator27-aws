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
