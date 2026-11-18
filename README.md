# MoreBees installer

One-line install for the **MoreBees** experiment orchestrator (RenAndStimPi) on an
Ubuntu Terminal PC or a Raspberry Pi.

## Install

Paste this line into a terminal on the computer you are setting up:

```sh
mb="$(mktemp)" && curl -fsSL -o "$mb" https://raw.githubusercontent.com/JConeLab/morebees-installer/6a034382e1749009fd15d781b45dfcb63d45379e/bootstrap.sh && echo "1c937f12069bca11af434e3e965d27260300719a36e4b2aa7aeda33fc6057405  $mb" | sha256sum -c --quiet - && bash "$mb"
```

The line downloads `bootstrap.sh` at one fixed commit of this repository, checks
it against its SHA-256 and runs it only when the check passes. Whatever is pushed
to this repository later, the line runs exactly the file it names: commit
`6a034382e1749009fd15d781b45dfcb63d45379e`, SHA-256
`1c937f12069bca11af434e3e965d27260300719a36e4b2aa7aeda33fc6057405`. A new
bootstrap reaches people only when this pin moves (see
[Releasing the bootstrap](#releasing-the-bootstrap)).

To pass options, put them after `bash "$mb"` at the end of the line, for example
`bash "$mb" --standalone --only 90`. To install a particular release, put the
variable before it: `RSO_GIT_REF=v0.5.0 bash "$mb"`.

The application repository is **private**. On a new computer the bootstrap:

1. **Checks the NVMe power settings first** on a Raspberry Pi 5 that starts from
   an NVMe drive. When it adds them to the boot line, it stops so that you can
   restart the Pi, and you run the same line again (see
   [A Raspberry Pi 5 that starts from an NVMe drive](#a-raspberry-pi-5-that-starts-from-an-nvme-drive)).
2. **Signs you in to GitHub once.** It prints a one-time code and a URL; open the
   URL in any browser (your phone works), enter the code and authorize with the
   GitHub account that has access to the app repository. Nothing else is asked:
   no git question, no Enter, and no browser opens on the computer itself.
3. **Clones the latest release** and **provisions unattended updates**: it
   generates a read-only
   [deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
   scoped to the app repository and registers it.
4. **Signs you out again** as soon as the computer can use its own deploy key:
   for the standalone role (a Raspberry Pi) before the installer starts, for the
   terminal role after the lab wizard has finished (the wizard may still need
   your sign-in).
5. **Hands off to the installer for this computer**, which asks for sudo and only
   for what it needs. At the end the bootstrap says plainly how the install
   ended.

## Two roles

The bootstrap picks the right installer for the hardware, and you can always say
so explicitly:

| Role | Default on | Installs |
|---|---|---|
| `--terminal` | a PC | **Lab setup wizard**: Terminal PC (PostgreSQL, database, venv), Task Pi deployment, ML Module, API service, health check, desktop icon |
| `--standalone` | a Raspberry Pi | **Single-rig Pi**: GUI, local NWB data, blue-green update layout. No Terminal PC, no database, no lab subnet |

A Raspberry Pi is detected automatically, because the lab wizard provisions a
Terminal PC (PostgreSQL, the API service, the rig subnet) and would be the wrong
install there. Pass `--terminal` to override.

## A Raspberry Pi that already has MoreBees

The bootstrap looks for an earlier install: `~/rso`, `/etc/rso/role`,
`/usr/local/bin/rso-standalone-gui` or `/usr/local/bin/renandstimpi-gui`. A
computer whose `/etc/rso/role` names another role (a Terminal PC, for example) is
not reinstalled as a standalone Pi.

A Pi is **provisioned** when `~/rso/current` exists and `/etc/rso/role` says
`standalone`, the installer's own rule; phase 70 sets up both at its cutover. A Pi
with an earlier install that is not provisioned is an install that stopped part
way. The bootstrap says "An unfinished MoreBees install was found; finishing it."
and takes the same steps as on a new Pi: it signs in, syncs
`~/projects/RenAndStimPi` to the release and runs that release's installer, which
finishes the install.

On a provisioned Pi the bootstrap itself never changes `~/projects` or `~/rso`
(the installer it starts does what you ask of it), and it signs in to GitHub only
when the Pi's own deploy key cannot fetch the release it needs.

- **`--only <phases>`** re-runs those phases with the installed release's own
  installer, from `~/rso/current` (or from the install folder named in
  `/usr/local/bin/renandstimpi-gui` when `~/rso/current` has no installer), with
  no sign-in and no clone. When neither has an installer, it stops with nothing
  changed. Give phases by number, for example `--only 90`: names such as
  `camera` need an installer from v0.5.0-rc.1 or later, and an older installer
  runs nothing for a phase it does not know (v0.4.9 has no names and no phase
  75), while still ending with status 0. `--help` shows the installed release's
  phases.
- On any Pi with an earlier install, phases 20 (`daqhats`), 70 (`blue_green`), 75
  (`camera`) and 90 (`hardware`) stop or replace what a running MoreBees uses, so
  before an `--only` run of one of them the bootstrap checks that no MoreBees
  window, task or hardware setup is running and that the camera recorder has no
  session open; otherwise it stops and says what is running.
- **`--help` or `--dry-run`** without `--only` runs the installed release's
  installer with your arguments, as you and not as root: it prints its help or
  its plan and changes nothing.
- **A full run** (no `--only`) reinstalls. The bootstrap picks the release:
  `RSO_GIT_REF` when set (a release tag, not a branch or a commit, and never older
  than the installed release unless you add `--allow-older-release`); otherwise
  the installed release when its installer can reinstall; otherwise the newest
  stable release newer than the installed one. It prepares that release's
  installer in a temporary copy under `~/.cache/morebees` (a local copy, no
  download unless the release is missing locally), and that installer asks what
  to do with the data on the Pi: keep it or delete it. Apart from the NVMe
  question below, which comes first, the bootstrap asks nothing itself and
  passes your options on unchanged (`--reinstall`,
  `--confirm-delete=...`, `--non-interactive`, `--inventory`, `--skip-phase`,
  `--verbose`, `--allow-older-release`). The temporary copy is removed when the
  run ends; when the installer, which runs as root, left files there that you
  cannot remove, the bootstrap removes the copy with sudo.
- Releases whose installer cannot keep or delete data (the first that can is
  planned for v0.5.1) are not reinstalled: the bootstrap explains, lists the
  newest release tags and stops with nothing changed. Your recorded sessions are
  in `~/rso/shared/data`: never remove `~/rso`.
- A computer whose `/etc/rso/role` names another role (a Terminal PC, for
  example) is not reinstalled as a standalone Pi.
- On a Raspberry Pi 5 that starts from an NVMe drive, the
  [NVMe power check](#a-raspberry-pi-5-that-starts-from-an-nvme-drive) runs
  before an `--only` run or a reinstall hands off.

## A Raspberry Pi 5 that starts from an NVMe drive

Some NVMe drives disconnect from a Raspberry Pi 5 under heavy writes, such as an
install: the kernel logs `nvme nvme0: controller is down`, and the Pi cannot
write to its disk until it restarts. Three kernel settings on the boot line,
`/boot/firmware/cmdline.txt`, turn off the drive's and the PCIe link's power
saving; with them, the two drives seen to disconnect so far ran an install, a
restart and a session without a storage error:

```text
nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off
```

They are not Raspberry Pi defaults, and with them the drive draws a little more
power and runs warmer, so the bootstrap does not add them everywhere. On a
Raspberry Pi 5 whose root filesystem is on an NVMe drive and whose boot line lacks
any of them, the bootstrap:

- **adds the missing ones by itself** when the drive is a model known to
  disconnect (so far the Kingston KC3000 and the Lexar NM620) or when this boot's
  kernel log already shows `controller is down`, and prints one line: what it
  added, why, and how to undo it;
- **otherwise asks**, and the answer is No unless you type `y`. With no terminal
  to ask on, or with `--non-interactive`, it asks nothing and changes nothing;
  `--add-nvme-power-settings` at the end of the command adds them without
  asking.

A root filesystem on LVM or LUKS over an NVMe drive counts as on that drive (the
bootstrap reads the device stack with `lsblk`). On an SD card, a USB drive, any
other Pi model, or a boot line that already has all three settings, nothing is
changed and nothing is asked. The bootstrap reads the line as the kernel does:
`-` and `_` are the same in a setting's name, so `pcie-aspm=force` is the
setting `pcie_aspm`. A boot line that gives one of them another value
(`pcie_aspm=force`, for example) is left to you, and so is a line with a bare
`--`, after which the kernel passes everything to init.

**How the line changes.** Only the missing settings are added, at the end of the
line. The rest of the line stays byte for byte, and it stays one line, ending
with a newline only if it did before. A copy of the old line is kept as
`/boot/firmware/cmdline.txt.before-morebees-nvme`. An earlier copy is never
overwritten: when it holds another line, the new copy gets the date and time in
its name. The new line is written to a temporary file in the same folder, checked
to read back as exactly the old line plus the settings, written through to the
drive with the copy (the boot partition is FAT, which has no journal), and moved
into place. The bootstrap's log gets the line before and after, both SHA-256
sums and the exact undo command before the move, and a Ctrl+C or a hang-up
from just before the move until the stop for the restart is held off. If any of
these checks fails, nothing is changed and the bootstrap says why. When the
settings are needed (a drive known to disconnect, or a disconnect this boot) or
were asked for, it then stops with status 3, before the sign-in, and says how to
add them by hand; otherwise the install carries on. On a Pi that already has
MoreBees, nothing is changed while MoreBees is in use: the bootstrap stops with
status 3 when the settings are needed or asked for, and otherwise does not
ask.

**Restart, then run the same line again.** The kernel reads the boot line only
when the Pi starts, so after a change the bootstrap stops with status 5, before
the GitHub sign-in and the clone: restart the Pi (`sudo reboot`) and run the same
command again. Running it again before the restart stops the same way, with
status 5: the bootstrap records the boot in which it changed the line. When the
settings are on the boot line but the running system did not start with them
after a restart, the Pi does not start from that line (look for `cmdline=` or
`os_prefix=` in `/boot/firmware/config.txt`); the bootstrap says so, and stops
with status 3 where the settings are needed, or carries on elsewhere.

**When it runs.** On a new Pi, or one whose install stopped part way, it runs
first, before the sign-in. On a provisioned Pi it runs before an `--only` run or
a reinstall hands off: after the check for another role on the computer and,
for `--only` runs of phases 20, 70, 75 and 90, after the check that MoreBees is
not in use. On a reinstall it runs before the release is chosen, so a run that
is later refused for its release can still stop first for a restart, and its
question can come before the reinstall's. `--help` and `--dry-run` skip it.

**To undo** the settings, run the undo command the bootstrap printed and logged,
then restart. It puts the old line back only while the boot line is still the
one the bootstrap wrote, so a line changed since (a drive cloned with new
partition IDs, or an edit by `raspi-config`) is never replaced by a stale one:

```sh
echo '<sha256 of the new line>  /boot/firmware/cmdline.txt' | sha256sum -c --quiet \
  && sudo cp /boot/firmware/cmdline.txt.before-morebees-nvme /boot/firmware/cmdline.txt
sudo reboot
```

When the check fails (`FAILED`), nothing is copied: remove the three settings
from the end of the line by hand instead. The log names the copy when it has a
dated name. On a drive known to disconnect, the next run of the bootstrap adds
the settings again, unless it is given `--no-nvme-power-settings`.

When a lab finds another model that disconnects, a part of its model name, as
`/sys/block/nvme0n1/device/model` gives it, goes into `NVME_DROP_MODELS` in
`bootstrap.sh` through a pull request, and reaches every lab with the next
bootstrap release (see [Releasing the bootstrap](#releasing-the-bootstrap)).
Until then, `--add-nvme-power-settings` adds the settings on that drive.

## Options

The role flags and the two NVMe flags are the bootstrap's own; every other
argument is forwarded to the installer that runs.

Bootstrap flags, for a Raspberry Pi 5 that starts from an NVMe drive (see
[A Raspberry Pi 5 that starts from an NVMe drive](#a-raspberry-pi-5-that-starts-from-an-nvme-drive)):

- `--add-nvme-power-settings` adds the NVMe power settings without asking, also
  when there is no terminal to ask on, for example
  `bash "$mb" --add-nvme-power-settings`.
- `--no-nvme-power-settings` never adds them and never stops for them, also on a
  drive known to disconnect, and says what that leaves: for a Pi whose settings
  were taken off on purpose, or one where they cause trouble.

The two together are refused, with nothing changed (status 3).

Wizard flags (Terminal PC): `--skip-taskpi`, `--skip-ml`, `--include-standalone`,
`--dev-mode` (skip rig-subnet networking on computers without the second network
port), `--non-interactive`. For example, a Terminal PC without the rig network:
`bash "$mb" --skip-taskpi --skip-ml --dev-mode`; the full lab:
`bash "$mb" --start-rig-id 01`.

Standalone-Pi flags: `--only <phases>`, `--skip-phase <phase>`, `--dry-run`,
`--verbose`, `--non-interactive`, and on releases that can reinstall,
`--reinstall keep|delete`, `--confirm-delete=<name>`, `--inventory`,
`--allow-older-release`. For example, to re-run only the DAQ HAT library phase:
`bash "$mb" --standalone --only 20`. Phases go by number; names (`daqhats`,
`camera`) work with installers from v0.5.0-rc.1 on.

Environment variables (put them before `bash "$mb"`):

| Variable | Meaning | Default |
|---|---|---|
| `RSO_APP_REPO` | app repository slug | `JConeLab/RenAndStimPi` |
| `RSO_GIT_REF` | tag, branch or SHA to install (a reinstall takes release tags only) | latest stable `vX.Y.Z` |
| `GH_TOKEN` | pre-issued token for fully headless installs | none (browser device flow) |

## How a run ends

The bootstrap exits with the installer's own status, or with its own when it
stops before the installer runs, and says what it means:

| Status | Meaning |
|---|---|
| 0 | MoreBees is installed. |
| 2 | Installed with problems; the installer's log names them. |
| 3 | Stopped before installing; nothing was changed. The message above says why. |
| 4 | The reinstall did not finish, and the previous installation was put back. |
| 5 | The bootstrap added the NVMe power settings to the boot line and stopped before installing, or found that restart still to come. Restart the Pi, then run the same command again. An installer that stops with 5 makes the bootstrap exit 1, with a failure report. |
| 129, 130, 143 | Interrupted. Run the same command again: it finishes or undoes what was started. |
| 1 or another | Something failed; a failure report to copy and paste is printed. |

The closing line "Future updates arrive inside the app" appears only when it is
true: the deploy key reached GitHub during the run, and the app runs from
`~/rso/current`, which fetches through that key.

## Logs

- **The bootstrap's log**: `~/.local/state/morebees/bootstrap-<date>-<pid>.log`
  (under `$XDG_STATE_HOME` when that is set), readable only by you (mode 0600).
  It holds the bootstrap's own messages, the installer's command line and its exit
  status, and after an NVMe change the boot line before and after, both SHA-256
  sums and the undo command. Its path is printed at the end of every run. It is
  not a copy of the installer's output: the installers keep their own logs, and
  copying their output would turn off their live progress line.
- **The standalone installer's log**: `/var/log/renandstimpi_standalone_installer.log`.
- **The lab wizard's log** (Terminal PC): `/tmp/rso_deploy_wizard_<date>.log`, named
  at the top of the wizard's output, and the Terminal installer's
  `/tmp/rso_installer.log`.

## Your GitHub sign-in

- **What it is for.** The app repository is private. The sign-in lets this
  computer clone it and register the computer's read-only deploy key, which needs
  an account with admin rights on the repository. Once the key works, the
  computer updates with the key alone, and the bootstrap signs you out.
- **What the token can do.** GitHub's device flow gives `gh` a token with the
  scopes `repo`, `read:org` and `gist` (gh's minimum). `repo` grants read and
  write access to every repository your account can reach, so the token is kept
  on the computer for as short a time as possible: with the standalone role it is
  removed as soon as the deploy key works, before the installer runs. The
  bootstrap never asks gh's git question, so the token does not get the
  `workflow` scope.
- **Signing out is not revoking.** Signing out removes the token from the
  computer (and gh's credential-helper lines from `~/.gitconfig`), but the token
  stays valid on GitHub until you revoke it, or until GitHub revokes it after a
  year without use. To revoke it: <https://github.com/settings/applications>,
  under *Authorized OAuth Apps*, *GitHub CLI*, *Revoke*. That removes the GitHub
  CLI's access everywhere you signed in with it, not only on this computer.
- When the deploy key could not be registered or verified, the session is kept so
  that the computer stays updatable, and the bootstrap says so; revoke it on the
  same page when you no longer need it.

## Security notes

- The one-liner is pinned to a commit and checks the file's SHA-256 before it
  runs, so a later change to this repository cannot change what the line runs.
- This script contains **no secrets** and never asks you to paste a token into a
  command line. Authentication is GitHub's official device flow through the `gh`
  CLI.
- The whole script runs inside a `main()` called on the last line, so a truncated
  download can never run half a script.
- The deploy key left on the computer is **read-only** and scoped to the single
  app repository; revoke it at any time under the app repository's
  *Settings*, *Deploy keys*.
- To read the script before running it, run the first part of the one-liner, then
  `less "$mb"`, then `bash "$mb"`.

## Requirements

- Ubuntu 22.04 or 24.04 (Terminal PC) or Raspberry Pi OS Bookworm (Pi)
- A GitHub account with read access to the app repository
- `sudo` rights on the computer

## Troubleshooting

- **"this GitHub account cannot access ..."**: your account lacks read access to
  the private app repository; ask an admin to invite you. The session that was
  used stays signed in, and the bootstrap prints how to remove it.
- **"could not register the deploy key automatically"**: registering deploy keys
  needs repo-admin permission. The public key is printed; send it to an admin to
  add under *Settings*, *Deploy keys* (read-only), then re-run the printed command.
- **"MoreBees is in use"**: an `--only` run of phase 20, 70, 75 or 90 found a
  MoreBees window, a task, the hardware setup, or a camera session. Let it finish
  or close it, then run the command again.
- **`sha256sum: WARNING: 1 computed checksum did NOT match`**: the download is not
  the pinned file. Nothing was run. Copy the line again from this README.
- **A Pi 5's NVMe drive disconnects** (`nvme nvme0: controller is down` in
  `journalctl -k`, and the Pi can no longer write to its disk): restart the Pi.
  During a first install, run the one-liner again with
  `--add-nvme-power-settings` at the end, or answer `y` when the bootstrap asks:
  it adds the NVMe power settings to the boot line and stops with status 5;
  restart the Pi again and run the same command once more. On a Pi that already
  has MoreBees, close MoreBees, then run the one-liner with
  `--only 10 --add-nvme-power-settings` at the end: the bootstrap adds the
  settings and stops with status 5 before phase 10 runs, so nothing is
  reinstalled, and after the restart nothing more is needed. To undo the
  settings, see
  [A Raspberry Pi 5 that starts from an NVMe drive](#a-raspberry-pi-5-that-starts-from-an-nvme-drive).

## For maintainers

### Tests and CI

`bash tests/run_tests.sh` runs the bootstrap end to end in a sandbox, with `gh`,
`sudo` and the installers stubbed, a stand-in device tree, boot folder, sysfs,
boot ID, `lsblk` and kernel log for the NVMe check, and real git against a small
stand-in for the app repository (Linux or macOS; it needs git and bash). No test
reads or changes the computer it runs on. Every shell file must be clean under
ShellCheck 0.11.0: `shellcheck bootstrap.sh scripts/*.sh tests/*.sh`.
`.github/workflows/ci.yml` runs both on every pull request and on every push to
`main`.

### Trying a branch on a Pi

Before release, run the bootstrap from a branch's raw URL; there is no checksum
to check, because a branch moves:

```sh
mb="$(mktemp)" && curl -fsSL -o "$mb" https://raw.githubusercontent.com/JConeLab/morebees-installer/<branch>/bootstrap.sh && bash "$mb" --standalone
```

### Releasing the bootstrap

A commit cannot contain its own hash, so the pin always follows the code:

1. Merge the bootstrap change into `main` through a pull request with green CI.
2. On a new branch from `main`, run `scripts/pin.sh <the merged commit>`. It
   rewrites every pinned URL in this README and the SHA-256 of `bootstrap.sh` at
   that commit; `scripts/pin.sh --check` confirms the result.
3. Open a pull request titled `release: pin <short sha>` with only that change,
   and merge it. From then on the one-liner runs the new bootstrap.

Between steps 1 and 3 this README already describes the new bootstrap while the
line still runs the previous one, so keep that window short.

An older pin must keep working with newer app releases, because some people still
copy an old line. To undo a release, pin the previous commit again.
