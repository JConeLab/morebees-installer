# MoreBees installer

One-line install for the **MoreBees** experiment orchestrator (RenAndStimPi) on an
Ubuntu Terminal PC or Raspberry Pi:

```sh
curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh | bash
```

The application repository is **private** — the one line above is all you type, and
the bootstrap handles the rest:

1. **Sign in to GitHub once** — a device code appears; open the shown URL in any
   browser (your phone works), enter the code, and authorize with the GitHub
   account that has access to the app repository. No tokens to create or paste.
2. **Clones the latest release** and **provisions unattended updates**: generates
   a read-only [deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
   scoped to the app repository and registers it automatically.
3. **Hands off to the installer for this box** — see the two roles below. It
   asks for sudo and only for what it needs. Afterwards your personal account is
   signed back out — the box updates itself with its own deploy key.

## Two roles

The bootstrap picks the right installer for the hardware, and you can always say
so explicitly:

| Role | Default on | Installs |
|---|---|---|
| `--terminal` | a PC | **Lab setup wizard**: Terminal PC (PostgreSQL, database, venv), Task Pi deployment, ML Module, API service, health check, desktop icon |
| `--standalone` | a Raspberry Pi | **Single-rig Pi**: GUI, local NWB data, blue-green update layout. No Terminal PC, no database, no lab subnet |

A Raspberry Pi is auto-detected, because the lab wizard provisions a Terminal PC
(PostgreSQL, the API service, the rig subnet) and would be a guaranteed-wrong
install there. Pass `--terminal` to override.

```sh
# Single-rig Raspberry Pi (the flag is optional on a Pi)
curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh | bash -s -- --standalone
```

## Options

Role flags are consumed by the bootstrap; every other argument is forwarded to
the installer that runs:

```sh
# Full lab (Terminal PC + Task Pis + ML Module)
curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh | bash -s -- --start-rig-id 01

# Terminal PC only, on a test box without the rig network
curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh | bash -s -- --skip-taskpi --skip-ml --dev-mode
```

Wizard flags: `--skip-taskpi`, `--skip-ml`, `--include-standalone`, `--dev-mode`
(skip rig-subnet networking on boxes without the second NIC), `--non-interactive`.

Standalone-Pi flags: `--only <phases>`, `--skip-phase <phase>`, `--dry-run`,
`--verbose`, `--non-interactive`. For example, to re-run just the DAQ HAT
library phase:

```sh
curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh | bash -s -- --standalone --only 20
```

Environment overrides:

| Variable | Meaning | Default |
|---|---|---|
| `RSO_APP_REPO` | app repository slug | `JConeLab/RenAndStimPi` |
| `RSO_GIT_REF` | tag / branch / SHA to install | latest stable `vX.Y.Z` |
| `GH_TOKEN` | pre-issued token for fully headless installs | — (browser device flow) |

## Security notes

- This script contains **no secrets** and never asks you to paste a token into a
  command line. Authentication is GitHub's official device flow via the `gh` CLI.
- The whole script runs inside a `main()` called on the last line, so a truncated
  download can never execute a half-fetched script.
- The deploy key left on the machine is **read-only** and scoped to the single app
  repository; revoke it anytime under the app repo's *Settings → Deploy keys*.
- Prefer to inspect before running? Download first:

  ```sh
  curl -fsSL -o bootstrap.sh https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh
  less bootstrap.sh
  bash bootstrap.sh
  ```

## Requirements

- Ubuntu 22.04/24.04 (Terminal PC) or Raspberry Pi OS Bookworm (Pi)
- A GitHub account with read access to the app repository
- `sudo` rights on the machine

## Troubleshooting

- **“this GitHub account cannot access …”** — your account lacks read access to
  the private app repository; ask an admin to invite you.
- **“could not register the deploy key automatically”** — registering deploy keys
  needs repo-admin permission. The public key is printed; send it to an admin to
  add under *Settings → Deploy keys* (read-only), then re-run the printed command.
- Installer logs: `/tmp/rso_universal_installer.log` and
  `/tmp/rso_installer.log`.
