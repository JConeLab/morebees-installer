#!/usr/bin/env bash
# Every path through main() ends in exit, so the last line's "exit $?" only
# guards the curl | bash read (see the end of the file).
# shellcheck disable=SC2317
#
# MoreBees: one-line bootstrap installer
#
# Run it with the pinned one-liner in README.md, which downloads this file at a
# fixed commit, checks its SHA-256 and then runs it. A file cannot contain its
# own hash, so the pin lives in the README, and scripts/pin.sh rewrites it.
#
# Sets up MoreBees (RenAndStimPi) from one command. The app repository is
# PRIVATE, so on a new computer this script first signs you in to GitHub with
# your own account (a one-time browser device code, no tokens to paste), clones
# the latest release, provisions a read-only DEPLOY KEY for unattended updates,
# and hands off to the installer for this computer. The sign-in is removed from
# this computer as soon as the deploy key works (standalone Pi) or after the
# installer (terminal). The token stays valid on GitHub until it is revoked at
# https://github.com/settings/applications.
#
# On a provisioned Raspberry Pi (standalone role: ~/rso/current exists and
# /etc/rso/role says standalone), it signs in only when the Pi's own deploy key
# cannot fetch the release, and it never changes ~/projects or ~/rso. --only
# re-runs phases with the installed release's own installer; a full run hands off
# to the target release's installer, run from a temporary local copy, and that
# installer asks what to do with the data. A Pi whose first install stopped
# before phase 70's cutover is finished with the steps of a new Pi.
#
# On a Raspberry Pi 5 that starts from an NVMe drive, the NVMe power settings
# are checked first (nvme_power_check): before the sign-in on a new Pi, and
# before the hand-off on a provisioned one. When the bootstrap adds them to the
# boot line it stops with status 5, because they take effect only at the next
# boot: restart the Pi, then run the same command again.
#
# Two roles, one bootstrap:
#   terminal    (default on a PC) Lab setup wizard: Terminal PC install +
#               Task Pi(s) + ML Module + API service + desktop icon in one run.
#   standalone  (default on a Raspberry Pi, or --standalone) Single-rig Pi:
#               GUI, local NWB data, blue-green update layout. No Terminal PC,
#               no database, no lab subnet.
#
# Environment overrides:
#   RSO_APP_REPO   app repo slug           (default: JConeLab/RenAndStimPi)
#   RSO_GIT_REF    tag/branch/SHA to install (default: latest stable vX.Y.Z);
#                  a reinstall on an installed Pi takes release tags only
#   GH_TOKEN       pre-issued token for fully headless installs (skips the
#                  browser step; needs read access to the app repo)
#
# The role flags and the two NVMe flags are consumed here; every other arg is
# forwarded to the installer:
#   ... --standalone                           # single-rig Pi
#   ... --skip-taskpi --skip-ml --dev-mode     # terminal-only test box
#   ... --start-rig-id 01                      # full lab
#   ... --standalone --skip-phase 20           # Pi, skip the DAQ HAT lib
#   ... --add-nvme-power-settings              # Pi 5 on NVMe: add them, no question
#   ... --no-nvme-power-settings               # Pi 5 on NVMe: never add them or stop for them
#
# Exit status: the installer's own (0 installed, 2 installed with problems,
# 3 stopped before installing with nothing changed, 4 reinstall undone,
# 129/130/143 interrupted); 1 when the bootstrap itself fails, with a failure
# report to paste; 5 when the bootstrap added the NVMe power settings to the
# boot line and stopped for a restart, or found that restart still to come. An
# installer's own 5 becomes 1, with the failure report, and so does any other
# 5 on the way out (_on_exit), so that 5 always means the restart.
#
# Log: ${XDG_STATE_HOME:-~/.local/state}/morebees/bootstrap-<date>-<pid>.log,
# mode 0600: the bootstrap's own messages only. The installer keeps its own log;
# copying its output here would turn off its live progress line.
#
# Test seams (the test suite points these into a sandbox): MB_BIN_DIR,
# MB_ROLE_FILE, MB_RIGCAM_ENV, MB_RIGCAM_TIMEOUT, and for the NVMe check
# MB_DT_MODEL, MB_BOOT_DIR, MB_SYSFS, MB_PROC_CMDLINE, MB_BOOT_ID and MB_TTY (the
# terminal stdin is reattached to and the question is read from). The commands
# the check runs (findmnt, lsblk, journalctl, dmesg, sudo, sync) are found on
# PATH.
#
# This file contains no secrets. Everything below runs inside main(), called
# on the last line, so a truncated download can never execute half a script.
set -Eeuo pipefail

APP_SLUG="${RSO_APP_REPO:-JConeLab/RenAndStimPi}"
DEPLOY_ALIAS="github-rso"                     # scripts/setup_terminal_deploy_key.sh
DEPLOY_KEY="$HOME/.ssh/rso_deploy_ed25519"
STANDALONE_ENTRY="installers/standalone/install_standalone.sh"
# The standalone installer's record (installers/standalone/lib/common.sh). sudo
# resets the environment, so its RSO_STANDALONE_LOG override never reaches it.
STANDALONE_LOG="/var/log/renandstimpi_standalone_installer.log"
WIZARD_LOG="the wizard's log (/tmp/rso_deploy_wizard_<date>.log, named at the top of its output)"
BIN_DIR="${MB_BIN_DIR:-/usr/local/bin}"
ROLE_FILE="${MB_ROLE_FILE:-/etc/rso/role}"
RIGCAM_ENV="${MB_RIGCAM_ENV:-/etc/rso/rigcam.env}"
RIGCAM_TIMEOUT="${MB_RIGCAM_TIMEOUT:-10}"
DT_MODEL="${MB_DT_MODEL:-/proc/device-tree/model}"
BOOT_DIR="${MB_BOOT_DIR:-/boot/firmware}"
SYSFS="${MB_SYSFS:-/sys}"
PROC_CMDLINE="${MB_PROC_CMDLINE:-/proc/cmdline}"
TTY_DEV="${MB_TTY:-/dev/tty}"
BOOT_ID_FILE="${MB_BOOT_ID:-/proc/sys/kernel/random/boot_id}"

# The NVMe power settings: the three kernel settings the kernel itself suggested
# when a drive dropped off the PCIe bus of a Raspberry Pi 5 (app repository,
# WORKLIST W-191). They turn off the drive's and the PCIe link's power saving.
NVME_SETTINGS=(nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off)
# Drive models known to drop off the bus on a Pi 5 without those settings: the
# bootstrap adds them without asking on these. An entry matches, ignoring case,
# any part of the model the drive reports in sysfs (/sys/block/nvme0n1/device/model,
# "KINGSTON SKC3000S512G" for a Kingston KC3000). When a lab reports another
# model that drops, add a part of its model here.
NVME_DROP_MODELS=(KC3000 NM620)

DID_LOGIN=0          # this run created the GitHub session
SIGNIN_REACHED=0     # this run created or reused a GitHub session
SSH_VERIFIED=0       # the deploy key reached the app repository in this run
SIGNED_OUT=0
AUTH_FINISHED=0
IN_INSTALLER=0       # the installer is the foreground command
APP_DIR=""           # the checkout this run cloned or synced (new installs only)
BUILD=""             # temporary clone holding the target installer (installed Pi)
REF=""               # the release this run installs
ROLE=""              # terminal | standalone -- resolved by parse_role
ARGS=()              # everything left after the role flags are consumed
LOG_FILE=""
INSTALLER_LOG=""
BOOTSTRAP_STEP="startup"
INSTALLED=0          # standalone role: a MoreBees install was found ...
PROVISIONED=0        # ... and it is finished: ~/rso/current and role standalone
CUR="$HOME/rso/current"
CUR_OK=0             # ~/rso/current resolves to a git checkout
O=""                 # the installed release tag, empty when unknown
INSTALL_DIR=""       # the install folder baked into the renandstimpi-gui wrapper
SRC=""               # the local checkout a reinstall copies from
SRC_URL=""           # its origin
ONLY_INSTALLER=""    # --only on an installed Pi: the installer to run ...
ONLY_REF=""          # ... the tag it belongs to ...
ONLY_FROM=""         # ... and where it came from, in words
REMOTE_TAGS=""
LS_OUT=""
REF_KIND=""
SEMVER_CMP=""
NVME_FORCE=0         # --add-nvme-power-settings: add the NVMe power settings without asking
NVME_DECLINE=0       # --no-nvme-power-settings: never add them, and never stop for them
HAVE_TTY=0           # stdin is a terminal to ask on (main reattaches it when it can)
NVME_LINE=""         # a boot line as read, without its newline ...
NVME_NL=""           # ... and its newline, or nothing when it has none
NVME_WHY=""          # why a boot line cannot be used ...
NVME_KIND=""         # ... and what kind of problem that is (_nvme_read_line)
NVME_MISSING=""      # the NVMe power settings a command line lacks ...
NVME_CONFLICT=""     # ... and its parameters that give one of them another value
NVME_WANT=""         # the new boot line, written outside the boot folder ...
NVME_STAGED=""       # ... and its temporary copy in the boot folder, until the move
NVME_NEW_BACKUP=""   # a backup this run made, removed again when the change fails
NVME_DASHDASH=0      # the command line has a bare --: the kernel passes what follows to init
NVME_FAILED=""       # why a change the bootstrap decided on was not made
NVME_PENDING_NAME="nvme-restart-pending"  # in _state_dir: the boot in which this bootstrap changed the line, and the line's SHA-256
NVME_PENDING_BOOT="" # read from that record: the boot ...
NVME_PENDING_SUM=""  # ... and the SHA-256 of the line written then
NVME_RECORDED=1      # 0 when this run changed the line but could not record the restart it stops for
NVME_RESTART=""      # how a message says to restart (_nvme_restart_words)
NVME_RESTART_EXIT=0  # 1 just before the NVMe restart's exit 5, the only 5 a run ends with
NVME_FIX_HOW=""      # how to fix a boot line the bootstrap will not read (_nvme_fix_line) ...
NVME_FIX_CMD=""      # ... and a command for that, when there is one
NVME_CAN_ASK=0       # 1 when the NVMe check may ask: a terminal, and no --non-interactive ...
NVME_NO_ASK=""       # ... and why it may not
MB_IN_USE=()         # what _morebees_in_use found running

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

_log() {
    [[ -n "$LOG_FILE" ]] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
# A closed terminal (a dropped SSH session) must not change the exit status.
info() { echo -e "${BLUE}[bootstrap]${NC} $*" || true; _log "INFO  $*"; }
ok()   { echo -e "${GREEN}[bootstrap]${NC} $*" || true; _log "OK    $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*" >&2 || true; _log "WARN  $*"; }

_failure_report() {
    # Paste-able failure report: what a maintainer needs to debug from a
    # chat message instead of a photo of scrollback.
    local report os_name
    # shellcheck disable=SC1091  # the Pi's own file, read only for its name
    os_name="$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -sr)"
    report="---- bootstrap failure report (copy/paste this) ----
time:  $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
step:  ${BOOTSTRAP_STEP:-startup}
ref:   ${REF:-${RSO_GIT_REF:-<latest>}}
role:  ${ROLE:-unknown}
model: $(tr -d '\0' 2>/dev/null <"$DT_MODEL" || uname -m)
os:    $os_name"
    if [[ -n "$INSTALLER_LOG" ]]; then
        report="$report
installer log: $INSTALLER_LOG"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        report="$report
bootstrap log: $LOG_FILE"
    fi
    report="$report
----------------------------------------------------"
    printf '%s\n' "$report" >&2 || true
    _log "$report"
}

die() {
    echo -e "${RED}[bootstrap]${NC} $*" >&2 || true
    _log "ERROR $*"
    _failure_report
    exit 1
}

# refuse <line>...: stop before anything was changed (exit 3).
refuse() {
    local line
    for line in "$@"; do warn "$line"; done
    # A session this run created has nothing left to do once the run stops.
    if [[ "$DID_LOGIN" == 1 && "$SIGNED_OUT" == 0 ]]; then sign_out; fi
    exit 3
}

# _state_dir: the bootstrap's own folder, for its log and the record of a
# restart it asked for. XDG_STATE_HOME counts only when it is absolute.
_state_dir() {
    local base="${XDG_STATE_HOME:-}"
    [[ "$base" == /* ]] || base="$HOME/.local/state"   # XDG: relative paths are invalid
    printf '%s/morebees\n' "$base"
}

log_init() {
    # The bootstrap's own record: its messages, the installer's command line and
    # exit status. Not a copy of the installer's output: teeing it would make the
    # installer's stderr a pipe, and its live progress line needs a terminal
    # (rso_terminal_installer/lib/ui.sh, mb_ui_init).
    local dir stamp file sum=""
    dir="$(_state_dir)"
    stamp="$(date '+%Y%m%d-%H%M%S')"
    file="$dir/bootstrap-$stamp-$$.log"
    if ! ( umask 077 && mkdir -p "$dir" && : > "$file" ) 2>/dev/null; then
        warn "could not create a log under $dir; continuing without one."
        return 0
    fi
    chmod 600 "$file" 2>/dev/null || true
    LOG_FILE="$file"
    # The file this run came from, when it is one (curl | bash has none).
    local self="${BASH_SOURCE[0]:-}"
    if [[ -n "$self" && -f "$self" ]] && grep -qxF 'main "$@"; exit $?' "$self" 2>/dev/null; then
        sum="$( (sha256sum "$self" 2>/dev/null || shasum -a 256 "$self" 2>/dev/null) | cut -d' ' -f1)"
    fi
    _log "MoreBees bootstrap: role=$ROLE user=$(id -un 2>/dev/null || true) bootstrap.sh sha256=${sum:-unknown (piped)}"
    _log "arguments for the installer: ${ARGS[*]+"${ARGS[*]}"}"
}

parse_role() {
    # Consume the bootstrap's own flags, the role and the two NVMe flags;
    # everything else is forwarded in order, with split_equals_forms writing
    # --only=<k> and --skip-phase=<k> as two words (the installers refuse an
    # option they do not know).
    local a
    for a in "$@"; do
        case "$a" in
            --standalone) ROLE="standalone" ;;
            --terminal)   ROLE="terminal" ;;
            --add-nvme-power-settings) NVME_FORCE=1 ;;
            --no-nvme-power-settings) NVME_DECLINE=1 ;;
            *) ARGS+=("$a") ;;
        esac
    done

    if [[ -z "$ROLE" ]]; then
        # A Raspberry Pi cannot run the lab wizard (it provisions a Terminal
        # PC: PostgreSQL, the API service, the rig subnet), so defaulting to
        # it here would be a guaranteed-wrong install. Detect and say so.
        if grep -qi "raspberry pi" "$DT_MODEL" 2>/dev/null; then
            ROLE="standalone"
            info "Raspberry Pi detected -- installing the single-rig standalone setup."
            info "Pass --terminal to install the lab wizard flow instead."
        else
            ROLE="terminal"
        fi
    fi
}

split_equals_forms() {
    # Every released standalone installer and lab wizard reads --only and
    # --skip-phase as two words ("--only 20") and refuses "--only=20" as an
    # unknown option, while this script accepts both. Every hand-off forwards
    # ARGS, so rewriting the = forms here gives the installer or wizard of any
    # version the form it reads. An empty value is left as given, so it is
    # still refused instead of reaching an installer as an empty list, which
    # the standalone installer would read as every phase.
    local a split=()
    for a in ${ARGS[@]+"${ARGS[@]}"}; do
        case "$a" in
            --only=?*)       split+=(--only "${a#--only=}") ;;
            --skip-phase=?*) split+=(--skip-phase "${a#--skip-phase=}") ;;
            *)               split+=("$a") ;;
        esac
    done
    ARGS=(${split[@]+"${split[@]}"})
}

ensure_prereqs() {
    BOOTSTRAP_STEP="prerequisites"
    local missing=() cmd
    for cmd in git curl; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "installing prerequisites: ${missing[*]}"
        sudo apt-get update -qq || die "apt-get update failed while installing ${missing[*]}."
        sudo apt-get install -y --no-install-recommends "${missing[@]}" \
            || die "could not install ${missing[*]} with apt-get."
    fi

    if ! command -v gh >/dev/null; then
        info "installing the GitHub CLI (gh)…"
        if ! sudo apt-get install -y gh 2>/dev/null; then
            # Debian Bookworm (Raspberry Pi OS) has no gh package -- use the
            # official GitHub CLI apt repository (their documented install).
            sudo install -d -m 0755 /usr/share/keyrings
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                | sudo tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null \
                || die "could not download the GitHub CLI's signing key."
            sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            sudo apt-get update -qq || die "apt-get update failed after adding the GitHub CLI repository."
            sudo apt-get install -y gh || die "could not install the GitHub CLI (gh)."
        fi
    fi
}

github_signin() {
    BOOTSTRAP_STEP="github-sign-in"
    SIGNIN_REACHED=1
    if gh auth status --hostname github.com >/dev/null 2>&1; then
        info "already signed in to GitHub -- reusing that session"
    else
        echo
        info "One-time GitHub sign-in: a one-time code and a URL appear below."
        info "Open the URL on any device (your phone works), enter the code, and"
        info "authorize with the GitHub account that has access to $APP_SLUG."
        info "Nothing else is asked here, and no browser opens on this computer."
        echo
        # gh asks questions only when its stdin and stdout are both terminals
        # (IOStreams.CanPrompt), so with stdin from /dev/null it asks no git
        # question (a yes there adds the workflow scope), does not wait for
        # Enter, never opens a browser, and prints the URL; the device flow
        # still polls GitHub until you authorize. GH_PROMPT_DISABLED=1 says the
        # same through gh's own setting. Read in gh v2.23.0 (Debian Bookworm's)
        # and v2.104.0: auth/login/login.go sets Interactive only when
        # CanPrompt(); authflow's BrowseURL prints the URL when not interactive;
        # cli/oauth's DeviceFlow then waits in device.Wait, reading no stdin.
        GH_PROMPT_DISABLED=1 gh auth login --hostname github.com --git-protocol https --web </dev/null \
            || die "GitHub sign-in failed. Your account needs access to $APP_SLUG."
        DID_LOGIN=1
        _log "signed in to GitHub with a device code"
    fi
    # Let plain git use gh's credentials (the clone runs over https).
    gh auth setup-git --hostname github.com </dev/null \
        || die "could not let git use the GitHub sign-in (gh auth setup-git failed)."
    # Fail early if the account cannot see the app repo.
    GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "https://github.com/$APP_SLUG.git" HEAD >/dev/null 2>&1 \
        || die "this GitHub account cannot access $APP_SLUG -- ask an admin for read access."
    ok "GitHub access to $APP_SLUG confirmed"
}

_remove_gh_git_helpers() {
    # gh auth setup-git writes, per host, an empty helper (which cuts the chain
    # of helpers) and then "!<path>/gh auth git-credential". Without a session
    # they serve nothing, so both go; another tool's helper stays.
    local key rest
    for key in "credential.https://github.com.helper" "credential.https://gist.github.com.helper"; do
        git config --global --get-all "$key" >/dev/null 2>&1 || continue
        git config --global --unset-all "$key" "gh'? auth git-credential\$" >/dev/null 2>&1 || true
        rest="$(git config --global --get-all "$key" 2>/dev/null || true)"
        if [[ -z "${rest//[[:space:]]/}" ]]; then
            git config --global --unset-all "$key" >/dev/null 2>&1 || true
        fi
    done
}

sign_out() {
    SIGNED_OUT=1
    if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
        # gh refuses to log out a token that comes from the environment.
        _remove_gh_git_helpers
        info "the GitHub token came from GH_TOKEN or GITHUB_TOKEN; nothing was stored on this computer to sign out."
        info "That token stays valid on GitHub until you revoke it where it was made"
        info "(a personal access token: https://github.com/settings/tokens)."
        return 0
    fi
    gh auth logout --hostname github.com </dev/null >/dev/null 2>&1 || true
    _remove_gh_git_helpers
    info "signed your GitHub account out of this computer (it updates with its own deploy key)."
    info "The sign-in token stays valid on GitHub until you revoke it: https://github.com/settings/applications"
    _log "signed out of GitHub; gh's git credential helper lines removed from ~/.gitconfig"
}

resolve_release_ref() {
    BOOTSTRAP_STEP="resolve-release"
    # Sets $REF to $RSO_GIT_REF or the latest stable vX.Y.Z tag.
    REF="${RSO_GIT_REF:-}"
    if [[ -n "$REF" && ! "$REF" =~ ^[0-9a-f]{7,40}$ ]]; then
        # Validate an explicit pin BEFORE any work: a typo'd tag (the
        # classic: 0.4.7 for v0.4.7, field-found 2026-09-04) otherwise
        # survives until checkout and dies there with a cryptic "could not
        # check out". Raw SHAs are exempt -- ls-remote cannot list them.
        if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code \
                "https://github.com/$APP_SLUG.git" \
                "refs/tags/$REF" "refs/heads/$REF" >/dev/null 2>&1; then
            if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code \
                    "https://github.com/$APP_SLUG.git" \
                    "refs/tags/v$REF" >/dev/null 2>&1; then
                die "RSO_GIT_REF=$REF does not exist -- did you mean v$REF? (release tags carry the v prefix)"
            fi
            die "RSO_GIT_REF=$REF does not exist on $APP_SLUG (release tags look like vX.Y.Z)"
        fi
    fi
    if [[ -z "$REF" ]]; then
        # Two steps with explicit errors: a transient ls-remote failure used
        # to abort silently inside the $() under set -e, so neither message
        # below could ever print.
        local raw
        raw="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "https://github.com/$APP_SLUG.git" 'v*')" \
            || die "could not list release tags on $APP_SLUG (network problem? try again)."
        REF="$(printf '%s\n' "$raw" \
            | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
    fi
    [[ -n "$REF" ]] || die "no stable release tag (vX.Y.Z) found on $APP_SLUG"
    info "installing release: $REF"
}

ensure_app_clone() {
    BOOTSTRAP_STEP="clone-app"
    # Clone (or sync) the app at its canonical location, pinned to $REF.
    # ONE full download; the wizard's installer phase reuses this checkout.
    APP_DIR="$HOME/projects/RenAndStimPi"
    if [[ -d "$APP_DIR/.git" ]]; then
        info "existing checkout at $APP_DIR -- syncing to $REF"
        # --force: without it a tag moved upstream (mistag corrected at the
        # source) makes every rerun die here with a cryptic refusal.
        GIT_TERMINAL_PROMPT=0 git -C "$APP_DIR" fetch --tags --force origin \
            || die "could not fetch from the app repository."
        # Prefer the freshly fetched remote ref: `checkout --detach <branch>`
        # resolves the STALE local branch tip (fetch does not advance it), so
        # RSO_GIT_REF=main would silently install outdated code. Tags fall
        # through to the second form.
        GIT_TERMINAL_PROMPT=0 git -C "$APP_DIR" checkout --quiet --detach "origin/$REF" 2>/dev/null \
            || GIT_TERMINAL_PROMPT=0 git -C "$APP_DIR" checkout --quiet --detach "$REF" \
            || die "could not check out $REF (dirty checkout? commit/stash first)."
    else
        mkdir -p "$(dirname "$APP_DIR")"
        info "cloning the app to $APP_DIR (~600 MB download, progress below)…"
        GIT_TERMINAL_PROMPT=0 git clone --progress "https://github.com/$APP_SLUG.git" "$APP_DIR" \
            || die "could not clone $APP_SLUG into $APP_DIR (network problem? try again)."
        # origin/<ref> first: a bare branch name here trips git's DWIM
        # local-branch creation, which is incompatible with --detach
        # ("fatal: '--detach' cannot be used with '-b/-B/--orphan'",
        # field-found 2026-07-24 on the first branch-ref fresh install).
        GIT_TERMINAL_PROMPT=0 git -C "$APP_DIR" checkout --quiet --detach "origin/$REF" 2>/dev/null \
            || GIT_TERMINAL_PROMPT=0 git -C "$APP_DIR" checkout --quiet --detach "$REF" \
            || die "could not check out $REF in $APP_DIR."
    fi

    # The wizard flow needs the release-sync + credential fixes from v0.2.5.
    if [[ "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
       [[ "$(printf '%s\n' v0.2.5 "$REF" | sort -V | head -1)" != "v0.2.5" ]]; then
        die "this bootstrap requires release v0.2.5 or newer (found $REF)."
    fi

    # Assert the ENTRY POINT this role needs, rather than a second version
    # floor: the file is the fact, and a floor would have to be bumped by hand
    # every time the layout moves.
    if [[ "$ROLE" == "standalone" ]]; then
        [[ -f "$APP_DIR/$STANDALONE_ENTRY" ]] || die \
            "release $REF does not ship the standalone installer ($STANDALONE_ENTRY).
   Install a newer release (RSO_GIT_REF=vX.Y.Z before bash in the one-liner),
   or run the lab wizard flow instead with --terminal."
    else
        [[ -f "$APP_DIR/rso_core/tools/rso_deploy_wizard.sh" ]] \
            || die "lab wizard missing from $REF."
    fi
}

# provision_deploy_key <checkout> [<re-run command>]
provision_deploy_key() {
    BOOTSTRAP_STEP="deploy-key"
    # Give the box its own least-privilege, read-only SSH deploy key so updates
    # never depend on a person's account -- equally true for a standalone Pi,
    # whose in-app update pill runs `git ls-remote` against origin. Requires the
    # signed-in account to be a repo ADMIN to auto-register; otherwise the
    # public key is printed for an admin to add. --repo names the checkout whose
    # origin the setup script switches to the key (every release since v0.2.5
    # takes it).
    local repo_dir="$1"
    local setup="$repo_dir/scripts/setup_terminal_deploy_key.sh"
    local rerun="${2:-bash $setup}"
    local pub="$DEPLOY_KEY.pub"

    [[ -d "$repo_dir/.git" ]] || return 0   # clone missing (should not happen)
    if [[ ! -f "$setup" ]]; then
        warn "this release has no deploy-key setup script -- updates will use your GitHub session instead."
        return 0
    fi

    echo
    info "provisioning the unattended-update deploy key…"
    if bash "$setup" --repo "$repo_dir"; then
        SSH_VERIFIED=1
        _log "deploy key verified"
        return 0
    fi

    # Pass 1 generated the key but GitHub does not know it yet -- register it.
    if [[ -f "$pub" ]] && gh repo deploy-key add "$pub" --repo "$APP_SLUG" \
            --title "MoreBees $(hostname) read-only ($(date +%F))" 2>/dev/null; then
        ok "deploy key registered on $APP_SLUG"
        # Guard the verify pass: an unguarded failure here (key-propagation
        # delay beyond the setup script's retry budget, or outbound ssh :22
        # blocked) used to abort the whole bootstrap BEFORE the wizard ran,
        # with the key already registered. Degrade to the kept-session path
        # instead -- finish_auth explains it.
        if bash "$setup" --repo "$repo_dir"; then
            SSH_VERIFIED=1
            _log "deploy key registered and verified"
        else
            warn "deploy key registered but not verified yet (GitHub propagation delay,"
            warn "or this network blocks outbound ssh port 22). Continuing; verify later with:"
            warn "    $rerun"
        fi
    else
        warn "could not register the deploy key automatically (repo-admin permission required)."
        warn "Send the public key printed above to a repository admin, then re-run:"
        warn "    $rerun"
    fi
}

finish_auth() {
    if [[ "$SIGNED_OUT" == 1 ]]; then
        :   # already signed out, right after the key verified (standalone)
    elif [[ "$SSH_VERIFIED" == 1 && "$SIGNIN_REACHED" == 1 ]]; then
        # The box now updates via its own deploy key -- drop the broad
        # personal token that was only needed for this bootstrap. F34: sign
        # out on the REUSE path too (not just when this run logged in) -- a
        # session left behind by an earlier aborted run otherwise lingers on
        # the box forever, and "whose session is it" is unknowable anyway.
        sign_out
    elif [[ "$DID_LOGIN" == 1 ]]; then
        warn "keeping your GitHub session so the box stays updatable."
        warn "You can revoke it anytime at https://github.com/settings/applications"
    elif [[ "$SIGNIN_REACHED" == 1 ]]; then
        warn "a reused GitHub session is still signed in on this box."
        warn "Once the deploy key works, sign it out with: gh auth logout --hostname github.com"
    fi
    AUTH_FINISHED=1
}

# _run_installer_cmd <command...>: run the installer as the foreground command
# and return its exit status. While it runs, a Ctrl+C or a hang-up is the
# installer's to handle, and _on_signal leaves it alone.
_run_installer_cmd() {
    local rc=0
    _log "running: $*"
    IN_INSTALLER=1
    "$@" || rc=$?
    IN_INSTALLER=0
    _log "installer exit status: $rc"
    return "$rc"
}

run_installer() {
    BOOTSTRAP_STEP="run-installer"
    echo
    if [[ "$ROLE" == "standalone" ]]; then
        INSTALLER_LOG="$STANDALONE_LOG"
        info "handing off to the MoreBees standalone-Pi installer (sudo password may be requested)…"
        echo
        # RSO_INSTALL_DIR points the installer at the checkout we already made:
        # without it phase 30 would clone the repo a SECOND time (~600 MB on a
        # Pi's SD card). The blue-green layout is adopted from this tree, after
        # which the app runs from ~/rso/current and this location is incidental.
        # Run as a child (NOT exec): the closing lines come after it.
        _run_installer_cmd sudo RSO_GIT_REF="$REF" RSO_INSTALL_DIR="$APP_DIR" \
            bash "$APP_DIR/$STANDALONE_ENTRY" "$@"
    else
        INSTALLER_LOG="$WIZARD_LOG"
        info "handing off to the MoreBees lab setup wizard (sudo password may be requested)…"
        echo
        _run_installer_cmd sudo RSO_GIT_REF="$REF" bash "$APP_DIR/rso_core/tools/rso_deploy_wizard.sh" "$@"
    fi
}

_git_net() {
    # git against the network with no prompts: no password question, and an
    # ssh that neither asks nor waits long for a port that is blocked.
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=20}" git "$@"
}

_origin_url() {
    # _origin_url <checkout>: origin's URL as configured (git remote get-url
    # would expand any url.insteadOf rule).
    git -C "$1" config --get remote.origin.url 2>/dev/null || true
}

_key_answers() {
    # _key_answers <checkout>: its origin is the deploy-key alias, and it answers.
    local origin
    origin="$(_origin_url "$1")"
    [[ "$origin" == "git@$DEPLOY_ALIAS:"* ]] || return 1
    _git_net -C "$1" ls-remote --exit-code origin HEAD >/dev/null 2>&1
}

_closing_update_line() {
    # "Future updates arrive inside the app" only when it is true: the app runs
    # from ~/rso/current, whose origin is the deploy-key alias, and the key
    # reached GitHub in this run.
    local origin=""
    if [[ -d "$CUR/.git" ]]; then
        origin="$(_origin_url "$CUR")"
    fi
    if [[ "$SSH_VERIFIED" != 1 ]] && _key_answers "$CUR"; then
        SSH_VERIFIED=1
    fi
    if [[ "$SSH_VERIFIED" == 1 && "$origin" == "git@$DEPLOY_ALIAS:"* ]]; then
        ok "Future updates arrive inside the app."
    elif [[ -z "$origin" ]]; then
        warn "There is no release folder at ~/rso/current, so updates do not arrive inside the app yet."
    elif [[ "$origin" != "git@$DEPLOY_ALIAS:"* ]]; then
        warn "The release in ~/rso/current does not fetch through this computer's deploy key ($origin),"
        warn "so updates inside the app need a GitHub sign-in."
    else
        warn "The deploy key did not reach GitHub in this run, so updates inside the app may not work yet."
    fi
}

_installer_failed() {
    local rc="$1" what="the standalone installer"
    [[ "$ROLE" == standalone ]] || what="the lab wizard"
    echo -e "${RED}[bootstrap]${NC} $what stopped with status $rc; see its output above." >&2 || true
    _log "ERROR $what stopped with status $rc"
    _failure_report
}

# run_end <installer exit status>: say what the status means, then exit with it.
run_end() {
    local rc="$1" what="MoreBees${REF:+ $REF}"
    BOOTSTRAP_STEP="run-installer"
    # Every write from here on is best effort: after a hang-up the terminal is
    # gone, and a failed write must not turn the installer's status into 1.
    echo || true
    if [[ "$ROLE" == standalone ]]; then
        case "$rc" in
            0) ok "$what is installed." ;;
            2) warn "$what is installed with problems; see $INSTALLER_LOG." ;;
            3) warn "Stopped before installing: see the installer's message above." ;;
            4) warn "The reinstall did not finish; the previous installation was put back. See $INSTALLER_LOG." ;;
            129|130|143) warn "Interrupted. Run the same command again: it finishes or undoes what was started." ;;
            *) _installer_failed "$rc" ;;
        esac
    else
        # The wizard defines 0, 1 and 3 (its re-run refusal); anything else
        # gets the failure report, as before.
        case "$rc" in
            0) ok "$what is installed." ;;
            3) warn "Stopped before installing: see the installer's message above." ;;
            *) _installer_failed "$rc" ;;
        esac
    fi
    if [[ "$rc" == 0 || "$rc" == 2 ]]; then
        _closing_update_line
    fi
    # 5 means the NVMe restart (nvme_power_check). An installer's own 5 is a
    # failure like any other, and the report above names it.
    if [[ "$rc" == 5 ]]; then
        rc=1
    fi
    exit "$rc"
}

# --- NVMe power settings on a Raspberry Pi 5 ----------------------------------
#
# Some NVMe drives drop off the PCIe bus of a Raspberry Pi 5 under heavy writes,
# and the root filesystem then turns read-only, unless the boot line turns off
# their power saving (app repository, WORKLIST W-191). On a Pi 5 whose root
# filesystem is on NVMe and whose boot line lacks any of NVME_SETTINGS,
# nvme_power_check adds the missing ones by itself when the drive is in
# NVME_DROP_MODELS or this boot's kernel log shows a drop. Otherwise it asks
# (No unless the answer is y), and with no terminal to ask on, or with
# --non-interactive, it adds them only for --add-nvme-power-settings. The kernel
# reads the boot line only at boot, so after a change the run stops with status
# 5 for a restart, and a run in that same boot stops again. Every change is
# reversible: a copy of the old line stays beside it, and the log has both
# SHA-256 sums and the undo command. A check that fails changes nothing; when
# the settings are needed or were asked for and cannot be added (a line it will
# not read, one that gives a setting another value, or one with a bare --), the
# run says what is wrong and why they are wanted, and asks whether to go on
# without them; No, or no terminal to ask on, stops it with status 3 rather
# than install without them. An empty boot line, from which the Pi would not
# start, stops the run on any drive. On an
# installed Pi nothing is changed, and no restart is advised, while MoreBees is
# in use. --no-nvme-power-settings turns the settings off: nothing is added,
# asked or stopped for, and the run says what that leaves.

_sha256() {
    (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null) | cut -d' ' -f1
}

# _nvme_nothing <reason>: there is nothing to add on this computer.
_nvme_nothing() {
    _log "NVMe power settings: nothing to do: $1"
    if [[ "$NVME_FORCE" == 1 ]]; then
        info "--add-nvme-power-settings: nothing to add, because $1."
    fi
}

# _nvme_root_source: the device the root filesystem is mounted from.
_nvme_root_source() {
    local src=""
    src="$(findmnt -n -o SOURCE / 2>/dev/null | tail -n 1)" || src=""
    printf '%s\n' "${src%%\[*}"     # a btrfs subvolume reads /dev/nvme0n1p2[/@]
}

# _nvme_root_disk <device>: the disk under the root filesystem's device, through
# any LVM or LUKS layer (lsblk walks the stack); when lsblk cannot say, the
# device's own disk from its name.
_nvme_root_disk() {
    local src="$1" disk=""
    if [[ "$src" == /dev/* ]] && command -v lsblk >/dev/null 2>&1; then
        disk="$(lsblk -nlso NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')" || disk=""
    fi
    if [[ -z "$disk" && "$src" =~ ^/dev/(nvme[0-9]+n[0-9]+)(p[0-9]+)?$ ]]; then
        disk="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$disk"
}

# _nvme_read_line <file>: read a boot line exactly. Sets NVME_LINE to the line
# and NVME_NL to its newline, or to nothing when the file has none. When the
# file is not one line of text, says why in NVME_WHY and what kind of problem
# in NVME_KIND (link, unreadable, changed, binary, lines, crlf, empty), and
# returns 1, or 2 when it holds no line at all (empty, or only blanks).
_nvme_read_line() {
    local f="$1" content="" all="" text="" LC_ALL=C
    NVME_LINE=""; NVME_NL=""; NVME_WHY=""; NVME_KIND=""
    if [[ -L "$f" ]]; then
        NVME_WHY="$f is a link"; NVME_KIND="link"
        return 1
    fi
    if [[ ! -f "$f" || ! -r "$f" ]]; then
        NVME_WHY="$f cannot be read"; NVME_KIND="unreadable"
        return 1
    fi
    all="$(wc -c <"$f" | tr -d '[:space:]')" || all=""
    text="$(tr -d '\000' <"$f" | wc -c | tr -d '[:space:]')" || text=""
    if [[ -z "$all" || "$all" != "$text" ]]; then
        NVME_WHY="$f holds a byte that is not text"; NVME_KIND="binary"
        return 1
    fi
    # The x keeps the newlines at the end, which command substitution drops.
    { content="$(cat -- "$f" && printf x)"; } 2>/dev/null || {
        NVME_WHY="$f cannot be read"; NVME_KIND="unreadable"
        return 1
    }
    content="${content%x}"
    if [[ "${#content}" != "$all" ]]; then
        NVME_WHY="$f changed while it was being read"; NVME_KIND="changed"
        return 1
    fi
    # Only blanks, newlines included: no line the Pi could start from.
    if [[ -z "${content//[[:space:]]/}" ]]; then
        NVME_WHY="$f is empty"; NVME_KIND="empty"
        return 2
    fi
    if [[ "$content" == *$'\n' ]]; then
        NVME_NL=$'\n'
        content="${content%$'\n'}"
    fi
    if [[ "$content" == *$'\n'* ]]; then
        NVME_WHY="$f has more than one line"; NVME_KIND="lines"
        return 1
    fi
    if [[ "$content" == *$'\r'* ]]; then
        NVME_WHY="$f has a Windows line ending (a carriage return)"; NVME_KIND="crlf"
        return 1
    fi
    NVME_LINE="$content"
}

# _nvme_root_word <file or text>: the root= word the kernel would read from a
# boot line, the first line up to any NUL byte and any bare --; nothing, and
# status 1, when there is none. With -t, the argument is the text itself.
_nvme_root_word() {
    local text="" w
    local -a ws=()
    if [[ "$1" == -t ]]; then
        text="$2"
    else
        IFS= read -r -d '' text <"$1" 2>/dev/null || true
    fi
    text="${text%%$'\n'*}"
    read -r -a ws <<<"$text" || true
    for w in ${ws[@]+"${ws[@]}"}; do
        [[ "$w" != "--" ]] || break
        w="${w%$'\r'}"
        if [[ "$w" == root=?* ]]; then
            printf '%s' "$w"
            return 0
        fi
    done
    return 1
}

# _nvme_scan <command line>: sets NVME_MISSING to the NVME_SETTINGS it lacks,
# NVME_CONFLICT to its parameters that give one of them another value, and
# NVME_DASHDASH to 1 when it has a bare --. It reads the line as the kernel
# does: - and _ are the same in a parameter's name, and what follows a bare --
# goes to init, not to the kernel.
_nvme_scan() {
    local s key w name found
    local -a words=()
    NVME_MISSING=""; NVME_CONFLICT=""; NVME_DASHDASH=0
    read -r -a words <<<"$1" || true
    for w in ${words[@]+"${words[@]}"}; do
        if [[ "$w" == "--" ]]; then
            NVME_DASHDASH=1
            break
        fi
    done
    for s in "${NVME_SETTINGS[@]}"; do
        key="${s%%=*}"
        found=0
        for w in ${words[@]+"${words[@]}"}; do
            [[ "$w" != "--" ]] || break
            name="${w%%=*}"
            [[ "${name//-/_}" == "$key" ]] || continue
            if [[ "$w" == *=* && "${w#*=}" == "${s#*=}" ]]; then
                found=1
            else
                NVME_CONFLICT="${NVME_CONFLICT:+$NVME_CONFLICT }$w"
            fi
        done
        if [[ "$found" == 0 ]]; then
            NVME_MISSING="${NVME_MISSING:+$NVME_MISSING }$s"
        fi
    done
}

# _nvme_model <disk>: the drive's model as sysfs reports it, trimmed.
_nvme_model() {
    local m=""
    m="$(cat "$SYSFS/block/$1/device/model" 2>/dev/null)" || m=""
    m="${m#"${m%%[![:space:]]*}"}"
    printf '%s\n' "${m%"${m##*[![:space:]]}"}"
}

# _nvme_known_drop <model>: the model matches an entry of NVME_DROP_MODELS.
_nvme_known_drop() {
    local model entry
    [[ -n "$1" ]] || return 1
    model="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for entry in "${NVME_DROP_MODELS[@]}"; do
        entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
        if [[ -n "$entry" && "$model" == *"$entry"* ]]; then
            return 0
        fi
    done
    return 1
}

# _nvme_drop_logged: this boot's kernel log shows an NVMe drive dropping off the
# bus ("nvme nvme0: controller is down; will reset: ..."): the journal's kernel
# messages, else the kernel's own buffer.
_nvme_drop_logged() {
    local out=""
    out="$(journalctl -k -b 0 --no-pager -q 2>/dev/null)" || out=""
    if [[ -z "$out" ]]; then
        out="$(dmesg 2>/dev/null)" || out=""
    fi
    grep -qE 'nvme[0-9]+: controller is down' <<<"$out"
}

# _nvme_ask <model>: ask on the terminal; returns 0 for yes. Anything but y or
# yes, an empty answer included, is No.
_nvme_ask() {
    local ans="" verdict=no
    warn "This Raspberry Pi 5 starts from an NVMe drive (${1:-its model could not be read}), and its boot line"
    warn "($BOOT_DIR/cmdline.txt) lacks: $NVME_MISSING"
    warn "Without these settings some drives disconnect on a Pi 5, and the Pi then cannot write to its"
    warn "disk until it restarts. They turn off the drive's power saving, so it runs a little warmer."
    warn "This drive is not a model known to disconnect, and this boot's kernel log shows no disconnect."
    printf '%b' "${YELLOW}[bootstrap]${NC} Add them now? This run then stops so that you can restart the Pi. [y/N] " >&2 || true
    read -r ans || true
    # A terminal echoes the Enter that ends the answer; anything else does not.
    [[ -t 0 ]] || { echo >&2 || true; }
    case "$ans" in
        [Yy]|[Yy][Ee][Ss]) verdict=yes ;;
    esac
    _log "NVMe power settings: asked; answer [$ans]: $verdict"
    [[ "$verdict" == yes ]]
}

# _nvme_cleanup: remove what a change that did not happen left: the temporary
# file in the boot folder, a backup this run made, and the prepared new line.
# Only what is there: a sudo that refused the first command must not be asked
# again for a file it never made.
_nvme_cleanup() {
    if [[ -n "$NVME_STAGED" ]]; then
        if [[ -e "$NVME_STAGED" || -L "$NVME_STAGED" ]]; then
            sudo rm -f -- "$NVME_STAGED" </dev/null 2>/dev/null \
                || warn "could not remove $NVME_STAGED; remove it with: sudo rm -f -- $NVME_STAGED"
        fi
        NVME_STAGED=""
    fi
    if [[ -n "$NVME_NEW_BACKUP" ]]; then
        if [[ -e "$NVME_NEW_BACKUP" || -L "$NVME_NEW_BACKUP" ]]; then
            sudo rm -f -- "$NVME_NEW_BACKUP" </dev/null 2>/dev/null \
                || warn "could not remove $NVME_NEW_BACKUP; remove it with: sudo rm -f -- $NVME_NEW_BACKUP"
        fi
        NVME_NEW_BACKUP=""
    fi
    if [[ -n "$NVME_WANT" ]]; then
        rm -f -- "$NVME_WANT" 2>/dev/null || true
        NVME_WANT=""
    fi
}

# _nvme_not_changed <why>: a check failed: undo what was made, and keep why in
# NVME_FAILED for the caller (_nvme_go_on_or_stop).
_nvme_not_changed() {
    _nvme_cleanup
    NVME_FAILED="$1"
    _log "NVMe power settings: not changed: $1"
}

# _nvme_restart_words: sets NVME_RESTART to how to say "restart the Pi". On an
# installed Pi while MoreBees is in use, a restart would end it: the run lists
# what runs, the words say to wait for it, and the function returns 1.
_nvme_restart_words() {
    local found
    NVME_RESTART="restart the Pi (sudo reboot)"
    if [[ "$INSTALLED" == 1 ]] && _morebees_in_use; then
        warn "MoreBees is in use, and a restart would end it:"
        for found in "${MB_IN_USE[@]}"; do warn "  $found"; done
        NVME_RESTART="once what is running has finished and MoreBees is closed, restart the Pi"
        return 1
    fi
    return 0
}

# _nvme_go_on_or_stop <what is wrong> <why they are wanted> <how to fix it, or
# nothing> [<a command for that, on a line of its own>]: the settings are
# wanted, and the bootstrap cannot put them in effect itself. It says what is
# wrong, why they are wanted and how to fix it, then asks whether to go on
# without them (No unless y); No stops the run with nothing changed (status 3).
# With no terminal to ask on, or with --non-interactive, nothing is asked, and
# the run stops the same way. Settings and commands to copy end their line.
_nvme_go_on_or_stop() {
    local ans=""
    warn "$1"
    warn "They are wanted because $2: a drive that disconnects leaves the Pi unable to write to its disk until it restarts."
    _nvme_restart_words || true
    if [[ -n "$3" ]]; then
        warn "$3"
        # printf, not warn: echo -e would read a backslash in the command.
        if [[ -n "${4:-}" ]]; then printf '  %s\n' "$4" >&2 || true; fi
        warn "Then ${NVME_RESTART}, and run the same command again."
    else
        warn "To use them, ${NVME_RESTART}, and run the same command again."
    fi
    if [[ "$NVME_CAN_ASK" != 1 ]]; then
        _log "NVMe power settings: not asked whether to go on without them ($NVME_NO_ASK); stopped"
        refuse "The bootstrap stops here rather than install without them, since $NVME_NO_ASK. Nothing was changed." \
            "To go on without them, run the same command with --no-nvme-power-settings."
    fi
    printf '%b' "${YELLOW}[bootstrap]${NC} Go on without them? Nothing on the boot line changes. [y/N] " >&2 || true
    read -r ans || true
    # A terminal echoes the Enter that ends the answer; anything else does not.
    [[ -t 0 ]] || { echo >&2 || true; }
    case "$ans" in
        [Yy]|[Yy][Ee][Ss])
            _log "NVMe power settings: asked whether to go on without them; answer [$ans]: yes"
            warn "Going on without the NVMe power settings, as you answered. If the drive disconnects, the Pi cannot write to its disk until it restarts."
            return 0 ;;
    esac
    _log "NVMe power settings: asked whether to go on without them; answer [$ans]: no"
    refuse "Stopped, as you answered. Nothing was changed." \
        "To go on without them next time, without this question, run the same command with --no-nvme-power-settings."
}

# _nvme_conflict_words: each word of NVME_CONFLICT with the value that its
# setting needs, as "pcie_aspm=force (needs pcie_aspm=off)".
_nvme_conflict_words() {
    local w s name out=""
    local -a ws=()
    read -r -a ws <<<"$NVME_CONFLICT" || true
    for w in ${ws[@]+"${ws[@]}"}; do
        name="${w%%=*}"
        for s in "${NVME_SETTINGS[@]}"; do
            if [[ "${name//-/_}" == "${s%%=*}" ]]; then
                out="${out:+$out, }$w (needs $s)"
            fi
        done
    done
    printf '%s' "$out"
}

# _nvme_after_dashdash <line>: what follows the line's bare --, which the
# kernel passes to init.
_nvme_after_dashdash() {
    local w seen=0 out=""
    local -a ws=()
    read -r -a ws <<<"$1" || true
    for w in ${ws[@]+"${ws[@]}"}; do
        if [[ "$seen" == 1 ]]; then
            out="${out:+$out }$w"
        elif [[ "$w" == "--" ]]; then
            seen=1
        fi
    done
    printf '%s' "$out"
}

# _nvme_by_hand <settings>: how to add these settings to the boot line by hand,
# ending with the settings, so that nothing follows them when they are copied.
_nvme_by_hand() {
    printf 'To add them by hand, put these at the end of the one line in %s, after a space: %s' "$BOOT_DIR/cmdline.txt" "$1"
}

# _nvme_fix_line <settings>: for a boot line the bootstrap will not read
# (NVME_KIND), sets NVME_FIX_HOW to how to fix it and then add these settings
# by hand, ending with the settings, and NVME_FIX_CMD to a command for the fix
# when there is one.
_nvme_fix_line() {
    local f="$BOOT_DIR/cmdline.txt"
    NVME_FIX_CMD=""
    case "$NVME_KIND" in
        crlf)
            NVME_FIX_CMD="sudo sed -i 's/\r\$//' $f"
            NVME_FIX_HOW="To fix it, remove the carriage return with the command below, then put these at the end of the line, after a space: $1" ;;
        lines)
            NVME_FIX_HOW="To fix it, make it one line again, then put these at the end of it, after a space: $1" ;;
        binary)
            NVME_FIX_HOW="To fix it, remove the bytes that are not text (it must be one line of plain text), then put these at the end of it, after a space: $1" ;;
        changed)
            NVME_FIX_HOW="It changed while the bootstrap read it: run the same command again once nothing else edits it. To add them by hand, put these at the end of its one line, after a space: $1" ;;
        *)
            NVME_FIX_HOW="To fix it, make $f a plain file of one line that you can read, then put these at the end of it, after a space: $1" ;;
    esac
}

# _nvme_unbootable_stop <file> <what is wrong> <root device>: the boot line holds
# no root= that the kernel would read, so the Pi would not start from it: stop
# on any drive, and never advise a restart. A copy the bootstrap made is named
# only when it holds the root this Pi started from (/proc/cmdline's root=).
_nvme_unbootable_stop() {
    local f="$1" running="" root="" copy found="" put dev="$3"
    [[ -n "$dev" ]] || dev="its root filesystem's device"
    running="$(cat "$PROC_CMDLINE" 2>/dev/null)" || running=""
    root="$(_nvme_root_word -t "$running")" || root=""
    if [[ -n "$root" ]]; then
        # Newest last: the dated copies sort after the first, by date.
        for copy in "$BOOT_DIR"/cmdline.txt.before-morebees-nvme*; do
            if [[ -f "$copy" ]] && _nvme_read_line "$copy" && [[ "$(_nvme_root_word -t "$NVME_LINE")" == "$root" ]]; then
                found="$copy"
            fi
        done
    fi
    if [[ -n "$found" ]]; then
        put="A copy the bootstrap made, $found, holds the root this Pi started from ($root). Put it back with: sudo cp $found $f && sudo sync -- $f $BOOT_DIR"
    elif [[ -n "$root" ]]; then
        put="Write the line back from a copy or by hand; it must hold the root this Pi started from: $root"
    else
        put="Write the line back from a copy or by hand; it must name this Pi's root partition, $dev"
    fi
    _log "NVMe power settings: stopped: $f $2"
    refuse "$f $2: the Pi would not start from it. Do not restart the Pi until a working line is back." \
        "$put" \
        "Then run the same command again. The bootstrap changed nothing."
}

# _boot_id: this boot's ID, which changes at every start; empty when unknown.
_boot_id() {
    tr -d '[:space:]' 2>/dev/null <"$BOOT_ID_FILE" || true
}

# _nvme_mark_pending <sha256 of the new line>: record, before the move, that this
# run changes the boot line to that line in this boot and stops for a restart
# (_nvme_running_check reads it). The record is the running user's, in
# _state_dir; when it cannot be made, NVME_RECORDED is 0, and the stop says so.
_nvme_mark_pending() {
    local id dir
    id="$(_boot_id)"
    dir="$(_state_dir)"
    if [[ -z "$id" ]]; then
        NVME_RECORDED=0
        _log "NVMe power settings: the pending restart could not be recorded: no boot ID in $BOOT_ID_FILE"
    elif ( umask 077 && mkdir -p "$dir" && printf '%s %s\n' "$id" "$1" >"$dir/$NVME_PENDING_NAME" ) 2>/dev/null; then
        _log "NVMe power settings: restart pending, recorded for boot $id and the line with sha256 $1"
    else
        NVME_RECORDED=0
        _log "NVMe power settings: the pending restart could not be recorded: $dir/$NVME_PENDING_NAME could not be written"
    fi
}
# _nvme_read_pending: NVME_PENDING_BOOT and NVME_PENDING_SUM from the record, or
# empty when there is none.
_nvme_read_pending() {
    NVME_PENDING_BOOT=""; NVME_PENDING_SUM=""
    read -r NVME_PENDING_BOOT NVME_PENDING_SUM _ 2>/dev/null <"$(_state_dir)/$NVME_PENDING_NAME" || true
}
_nvme_clear_pending() {
    rm -f -- "$(_state_dir)/$NVME_PENDING_NAME" 2>/dev/null || true
}

# _nvme_apply <reason>: append NVME_MISSING to the boot line, reversibly.
# Returns 0 once the new line is in place, with INT, HUP and TERM ignored until
# the run stops for the restart, and 1 when a check failed and nothing was
# changed (NVME_FAILED says why). No sudo here reads the terminal: under
# Raspberry Pi OS's use_pty, a Ctrl+C would reach that command alone.
_nvme_apply() {
    local reason="$1" f="$BOOT_DIR/cmdline.txt" backup="$BOOT_DIR/cmdline.txt.before-morebees-nvme"
    local old_line="$NVME_LINE" nl="$NVME_NL" added="$NVME_MISSING" sep=" " new old_sum new_sum undo
    local stale stag mv_rc=0 rec
    NVME_FAILED=""
    # The settings go at the end of the line; the rest stays byte for byte.
    if [[ "$old_line" == *[[:blank:]] ]]; then
        sep=""
    fi
    new="$old_line$sep$added"
    NVME_WANT="$(mktemp "${TMPDIR:-/tmp}/morebees-cmdline.XXXXXX")" || NVME_WANT=""
    if [[ -z "$NVME_WANT" ]] || ! printf '%s%s' "$new" "$nl" >"$NVME_WANT"; then
        _nvme_not_changed "the new line could not be written to a temporary file"
        return 1
    fi
    # Said before the first sudo, which may ask for a password.
    info "Adding $added to the boot line ($f), because $reason; sudo may ask for your password."
    # A temporary file that an earlier run left when the power was cut before
    # its move: nothing names it after a restart, and the firmware never reads
    # it. It goes now. Each name carries the boot it was made in, so a file of
    # this boot, another run's that is still at work, is left alone.
    stag="$(_boot_id)"
    stag="${stag:0:8}"
    [[ -n "$stag" ]] || stag="noboot"
    for stale in "$BOOT_DIR"/cmdline.txt.morebees-new.*; do
        [[ -e "$stale" || -L "$stale" ]] || continue
        case "${stale##*/}" in "cmdline.txt.morebees-new.$stag".*) continue ;; esac
        if sudo rm -f -- "$stale" </dev/null; then
            _log "NVMe power settings: removed $stale, which an earlier run left"
        else
            warn "could not remove $stale, which an earlier run left; remove it with: sudo rm -f -- $stale"
        fi
    done
    # A copy of the line as it is now. An earlier copy is never overwritten:
    # when it holds another line, this one is copied under a dated name.
    if [[ -e "$backup" ]] && ! cmp -s "$backup" "$f"; then
        backup="$backup-$(date '+%Y%m%d-%H%M%S')"
    fi
    if [[ -e "$backup" ]]; then
        if ! cmp -s "$backup" "$f"; then
            _nvme_not_changed "$backup exists and holds another line"
            return 1
        fi
        _log "NVMe power settings: $backup already holds this line; it is kept as it is"
    else
        # Named before the copy, so that a copy that fails part way (a full boot
        # partition) leaves nothing under the name the undo uses.
        NVME_NEW_BACKUP="$backup"
        if ! sudo cp -- "$f" "$backup" </dev/null; then
            _nvme_not_changed "$f could not be copied to $backup"
            return 1
        fi
        if ! cmp -s "$f" "$backup"; then
            _nvme_not_changed "the copy $backup does not match $f"
            return 1
        fi
    fi
    # The new line goes to a temporary file in the same folder, which must read
    # back as one line holding the old line plus the settings and nothing else,
    # and is then moved into place in one step.
    NVME_STAGED="$(sudo mktemp "$BOOT_DIR/cmdline.txt.morebees-new.$stag.XXXXXX" </dev/null)" || NVME_STAGED=""
    if [[ -z "$NVME_STAGED" ]]; then
        _nvme_not_changed "no temporary file could be made in $BOOT_DIR"
        return 1
    fi
    if ! sudo cp -- "$NVME_WANT" "$NVME_STAGED" </dev/null; then
        _nvme_not_changed "the new line could not be written to $NVME_STAGED"
        return 1
    fi
    if ! _nvme_read_line "$NVME_STAGED"; then
        _nvme_not_changed "$NVME_WHY"
        return 1
    fi
    if [[ "$NVME_LINE" != "$new" || "$NVME_NL" != "$nl" ]] || ! cmp -s "$NVME_STAGED" "$NVME_WANT"; then
        _nvme_not_changed "$NVME_STAGED did not read back as the old line plus $added"
        return 1
    fi
    # The move replaces the whole file, so it must still hold the line read.
    if ! _nvme_read_line "$f" || [[ "$NVME_LINE" != "$old_line" || "$NVME_NL" != "$nl" ]]; then
        _nvme_not_changed "$f changed while the new line was prepared"
        return 1
    fi
    # Both files, and the folder's entries for them, reach the drive before the
    # rename points the boot line at the new one. The boot partition is FAT,
    # with no journal: after a power cut during a sync that follows the move,
    # cmdline.txt could name data never written (no root=, and the Pi does not
    # start), and the copy could be lost.
    if ! sudo sync -- "$NVME_STAGED" "$backup" "$BOOT_DIR" </dev/null; then
        _nvme_not_changed "the new line and its copy could not be written through to the drive"
        return 1
    fi
    old_sum="$(_sha256 "$f")"
    new_sum="$(_sha256 "$NVME_WANT")"
    # The undo puts the old line back only while the boot line is still the one
    # written here and its copy still the line before: a line changed since (a
    # clone given new partition IDs, raspi-config) is left as it is, and so is
    # a copy that no longer holds the line it was made from. It writes the line
    # in place, so it writes it through to the drive before anyone restarts.
    # It also removes the restart record, which names the line written here.
    printf -v rec '%q' "$(_state_dir)/$NVME_PENDING_NAME"
    undo="printf '%s  %s\n' $new_sum $f $old_sum $backup | sha256sum -c --quiet && sudo cp $backup $f && sudo sync -- $f $BOOT_DIR && rm -f -- $rec"
    # Nothing interrupts the record, the move and the stop that follows: a
    # Ctrl+C or a hang-up between them would leave a change with no record, no
    # undo line or no restart message, or a record of a change never made.
    trap '' INT HUP TERM
    _log "NVMe power settings: changing $f, because $reason"
    _log "NVMe power settings: line before: $old_line"
    _log "NVMe power settings: line after:  $new"
    _log "NVMe power settings: sha256 before $old_sum, after $new_sum"
    _log "NVMe power settings: the line before is kept in $backup"
    _log "NVMe power settings: undo command: $undo"
    _log "NVMe power settings: after the undo, restart the Pi"
    _nvme_mark_pending "$new_sum"
    # The status alone does not decide: the rename happened exactly when the
    # temporary file is gone.
    sudo mv -f -- "$NVME_STAGED" "$f" </dev/null || mv_rc=$?
    if [[ "$mv_rc" != 0 ]]; then
        if [[ -e "$NVME_STAGED" || -L "$NVME_STAGED" ]]; then
            _nvme_clear_pending
            _bootstrap_traps
            _nvme_not_changed "$NVME_STAGED could not be moved to $f"
            return 1
        fi
        _log "NVMe power settings: mv ended with status $mv_rc, but $NVME_STAGED is gone, so the line was moved"
    fi
    NVME_STAGED=""
    if ! cmp -s "$f" "$NVME_WANT"; then
        # The move went through, but the line did not read back: put the copy
        # back, written in place, so through to the drive as well.
        _nvme_clear_pending
        if sudo cp -- "$backup" "$f" </dev/null && cmp -s "$f" "$backup"; then
            sudo sync -- "$f" "$BOOT_DIR" </dev/null \
                || _log "NVMe power settings: sync -- $f $BOOT_DIR failed after the copy was put back"
            _bootstrap_traps
            _nvme_not_changed "$f did not read back as written, so its copy was put back"
            return 1
        fi
        die "$f did not read back as written, and its copy could not be put back.
   Before the Pi restarts, put it back with: sudo cp $backup $f && sudo sync -- $f $BOOT_DIR"
    fi
    # On the drive before anyone pulls the plug instead of restarting. On FAT a
    # plain sync writes the folder, where the temporary name is removed, and
    # the FAT after the drive's last flush, which can leave them in the drive's
    # cache. syncfs of the boot partition (sync -f) writes all of it, an entry
    # that unrelated writeback already took from the line's inode included;
    # fsync of the line, then of the folder, then flushes the drive. Neither
    # waits on an unrelated network mount the way sync(2) can while Ctrl+C is
    # held off.
    sudo sync -f -- "$f" </dev/null || _log "NVMe power settings: sync -f -- $f failed after the move"
    if ! sudo sync -- "$f" "$BOOT_DIR" </dev/null; then
        warn "the new boot line could not be written through to the drive; run sync before restarting the Pi."
        _log "NVMe power settings: sync -- $f $BOOT_DIR failed after the move"
    fi
    NVME_NEW_BACKUP=""
    rm -f -- "$NVME_WANT" 2>/dev/null || true
    NVME_WANT=""
    _log "NVMe power settings: changed $f"
    ok "Added $added to the boot line ($f), because $reason."
    info "To undo, run this, which puts the old line back only while the boot line and its copy are as written here, then restart the Pi:"
    # printf, not echo -e: the command holds a \n of its own.
    printf '  %s\n' "$undo" || true
    return 0
}

# _nvme_running_check <why the settings are needed, or nothing>: the settings
# are on the boot line. When the running system did not start with them: in
# the boot in which this bootstrap wrote this very line, the restart is still to
# come, so the run stops for it again (status 5, or 3 while MoreBees is in use);
# after a restart, the Pi does not start from this boot line. A record of
# another line is stale, and goes. Where the settings are needed, the run then
# stops (status 3) rather than install without them; elsewhere it says so and
# carries on.
_nvme_running_check() {
    local needed="$1" running="" now="" sum="" what="" fix=""
    running="$(cat "$PROC_CMDLINE" 2>/dev/null)" || return 0
    _nvme_scan "$running"
    if [[ -z "$NVME_MISSING" ]]; then
        _nvme_clear_pending
        return 0
    fi
    _log "NVMe power settings: not in effect: $PROC_CMDLINE lacks $NVME_MISSING"
    _nvme_read_pending
    now="$(_boot_id)"
    sum="$(_sha256 "$BOOT_DIR/cmdline.txt")"
    if [[ -n "$NVME_PENDING_BOOT" && "$NVME_PENDING_SUM" != "$sum" ]]; then
        _log "NVMe power settings: the restart record names another line, so it is dropped"
        _nvme_clear_pending
        NVME_PENDING_BOOT=""
    fi
    if [[ -n "$NVME_PENDING_BOOT" && -n "$now" && "$NVME_PENDING_BOOT" == "$now" ]]; then
        warn "The NVMe power settings were added to the boot line, but the Pi has not restarted since."
        if ! _nvme_restart_words; then
            refuse "The new boot line takes effect only after a restart, which would end what is running." \
                "Then, ${NVME_RESTART} and run the same command again. Nothing was changed."
        fi
        _nvme_restart_stop
    fi
    if [[ -n "$NVME_PENDING_BOOT" && -n "$now" ]]; then
        what="The Pi has restarted since the NVMe power settings were added, but it did not start with them: it does not start from $BOOT_DIR/cmdline.txt. Look for cmdline= or os_prefix= in $BOOT_DIR/config.txt."
        fix="To use them, have it start from the boot line that holds them."
    else
        what="The NVMe power settings are on the boot line, but this system did not start with them."
        fix=""
    fi
    if [[ -n "$needed" ]]; then
        _nvme_go_on_or_stop "$what" "$needed" "$fix"
    elif [[ -n "$fix" ]]; then
        warn "$what"
    else
        _nvme_restart_words || true
        warn "The NVMe power settings are on the boot line, but this system did not start with them: to use them, ${NVME_RESTART}."
    fi
}

# _nvme_declined <file> <why the settings are needed, or nothing>:
# --no-nvme-power-settings. The bootstrap neither adds the NVMe power settings
# nor stops for them, and says what that leaves, the running system included.
_nvme_declined() {
    local f="$1" needed="$2" state="could not be read" running=""
    if _nvme_read_line "$f"; then
        _nvme_scan "$NVME_LINE"
        if [[ -z "$NVME_MISSING" ]]; then
            state="has them"
        else
            state="lacks $NVME_MISSING"
            _nvme_clear_pending
        fi
    fi
    _log "NVMe power settings: declined (--no-nvme-power-settings): the boot line $state${needed:+; wanted because $needed}"
    if [[ "$state" == "has them" ]]; then
        running="$(cat "$PROC_CMDLINE" 2>/dev/null)" || running=""
        _nvme_scan "$running"
        if [[ -n "$running" && -n "$NVME_MISSING" ]]; then
            _log "NVMe power settings: not in effect: $PROC_CMDLINE lacks $NVME_MISSING"
            warn "--no-nvme-power-settings: the boot line ($f) has the NVMe power settings, but this system did not start with them: they take effect only after a restart, and this install runs without them."
            if [[ -n "$needed" ]]; then
                warn "They are wanted because $needed: if the drive disconnects during the install, the Pi cannot write to its disk until it restarts."
            fi
        else
            info "--no-nvme-power-settings: the boot line ($f) already has the NVMe power settings, and the bootstrap leaves it as it is."
        fi
    elif [[ -n "$needed" ]]; then
        warn "--no-nvme-power-settings: the NVMe power settings were not added, although $needed. If the drive disconnects, the Pi cannot write to its disk until it restarts."
    else
        info "--no-nvme-power-settings: the NVMe power settings were not added to the boot line ($f)."
    fi
}

# _nvme_restart_stop: the new line takes effect at the next boot (status 5, the
# only 5 a run ends with).
_nvme_restart_stop() {
    warn "Restart needed: the new boot line takes effect only after a restart, so this run stops here."
    if [[ "$NVME_RECORDED" == 0 ]]; then
        warn "This run could not record the restart it needs, so a run before the restart would not stop for it with status 5: restart first."
    fi
    warn "Restart the Pi (sudo reboot), then run the same command again."
    NVME_RESTART_EXIT=1
    exit 5
}

# nvme_power_check [installer arguments...]: the NVMe power settings, run before
# the first heavy write or the hand-off. --help and --dry-run change nothing, so
# they skip it.
nvme_power_check() {
    BOOTSTRAP_STEP="nvme-power-settings"
    local dt="" src="" disk="" model="" reason="" needed="" want="" why="" how="" found rl=0
    local f="$BOOT_DIR/cmdline.txt"
    if _has_info_flag "$@"; then
        _log "NVMe power settings: not checked: --help and --dry-run change nothing"
        return 0
    fi
    # Whether a question can be asked, here and in _nvme_go_on_or_stop.
    NVME_CAN_ASK=0
    NVME_NO_ASK="there is no terminal to ask on"
    if [[ "$HAVE_TTY" == 1 ]]; then
        if _args_have --non-interactive "$@"; then
            NVME_NO_ASK="--non-interactive asks nothing"
        else
            NVME_CAN_ASK=1
        fi
    fi
    # 2>/dev/null first: a missing file is reported by the shell, on its stderr.
    dt="$(tr -d '\0' 2>/dev/null <"$DT_MODEL")" || dt=""
    if [[ "$dt" != "Raspberry Pi 5 "* ]]; then
        _nvme_nothing "this is not a Raspberry Pi 5 (model: ${dt:-unknown})"
        return 0
    fi
    src="$(_nvme_root_source)"
    disk="$(_nvme_root_disk "$src")"
    if [[ ! "$disk" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        _nvme_nothing "the root filesystem is on ${src:-a device that could not be read}, not on an NVMe drive"
        return 0
    fi
    model="$(_nvme_model "$disk")"
    # A drive known to disconnect, or one that did this boot: the settings are
    # needed, and a run that cannot add them stops instead of installing.
    if _nvme_known_drop "$model"; then
        needed="this drive ($model) is a model known to disconnect without them"
    elif _nvme_drop_logged; then
        needed="this boot's kernel log shows the drive disconnecting (controller is down)"
    fi
    # Wanted without a question: needed, or asked for with the flag. A run that
    # cannot add what it wants asks whether to go on without them, and
    # otherwise stops with status 3 rather than install without them.
    want="$needed"
    if [[ -z "$want" && "$NVME_FORCE" == 1 ]]; then
        want="--add-nvme-power-settings asked for them"
    fi
    _nvme_read_line "$f" || rl=$?
    # A line the Pi would not start from, on any drive and whatever the flags:
    # empty, or with no root= that the kernel would read (a line of NUL bytes,
    # text that lost it, or a first line without it).
    if [[ "$rl" == 2 ]]; then
        _nvme_unbootable_stop "$f" "is empty" "$src"
    fi
    if [[ "$rl" == 0 || "$NVME_KIND" =~ ^(binary|lines|crlf)$ ]] && ! _nvme_root_word "$f" >/dev/null; then
        _nvme_unbootable_stop "$f" "holds no root= that the kernel would read" "$src"
    fi
    if [[ "$NVME_DECLINE" == 1 ]]; then
        _nvme_declined "$f" "$needed"
        return 0
    fi
    if [[ "$rl" != 0 ]]; then
        if [[ -n "$want" ]]; then
            _nvme_fix_line "${NVME_SETTINGS[*]}"
            _nvme_go_on_or_stop "The NVMe power settings were not added: $NVME_WHY. The boot line was not changed." \
                "$want" "$NVME_FIX_HOW" "$NVME_FIX_CMD"
            return 0
        fi
        warn "The NVMe power settings were not checked: $NVME_WHY. The boot line was not changed."
        return 0
    fi
    _nvme_scan "$NVME_LINE"
    if [[ -n "$NVME_MISSING" ]]; then
        # A restart record from a line that had them is stale now.
        _nvme_clear_pending
    fi
    if [[ -z "$NVME_MISSING$NVME_CONFLICT" ]]; then
        # All three are there, before any bare --, which then takes nothing.
        _nvme_nothing "the boot line already has all three settings"
        _nvme_running_check "$needed"
        return 0
    fi
    _log "NVMe power settings: Raspberry Pi 5, root on $src (drive $disk), model [$model], boot line lacks: ${NVME_MISSING:-nothing}"
    # A line the bootstrap leaves to the operator: another value for one of the
    # settings, or a bare --, after which the kernel passes everything to init.
    if [[ -n "$NVME_CONFLICT" || "$NVME_DASHDASH" == 1 ]]; then
        if [[ -n "$NVME_CONFLICT" ]]; then
            why="the boot line ($f) sets $(_nvme_conflict_words), which the bootstrap leaves to you"
            how="To use them, edit the one line in $f so that it holds these, with no other value for them and all before any bare --: ${NVME_SETTINGS[*]}"
        else
            found="$(_nvme_after_dashdash "$NVME_LINE")"
            why="the boot line ($f) has a bare --, after which the kernel passes everything to init (here: ${found:-nothing}), and the bootstrap leaves that to you"
            how="To add them by hand, put these before the bare -- in $f: $NVME_MISSING"
        fi
        if [[ -n "$want" ]]; then
            _nvme_go_on_or_stop "The NVMe power settings were not added: $why." "$want" "$how"
            return 0
        fi
        warn "The NVMe power settings were not added: $why."
        _log "NVMe power settings: not changed: $why"
        return 0
    fi
    if [[ -n "$want" ]]; then
        reason="$want"
    elif [[ "$HAVE_TTY" != 1 ]]; then
        info "This Pi 5 starts from an NVMe drive (${model:-model unknown}) whose boot line lacks $NVME_MISSING."
        info "There is no terminal to ask on, so the boot line was not changed. To add them, run again with --add-nvme-power-settings."
        _log "NVMe power settings: not asked (no terminal); not changed"
        return 0
    elif _args_have --non-interactive "$@"; then
        info "This Pi 5 starts from an NVMe drive (${model:-model unknown}) whose boot line lacks $NVME_MISSING."
        info "With --non-interactive nothing is asked, so the boot line was not changed. To add them, run again with --add-nvme-power-settings."
        _log "NVMe power settings: not asked (--non-interactive); not changed"
        return 0
    elif [[ "$INSTALLED" == 1 ]] && _morebees_in_use; then
        info "This Pi 5 starts from an NVMe drive (${model:-model unknown}) whose boot line lacks $NVME_MISSING."
        info "MoreBees is in use, and the settings take effect only after a restart, so nothing was asked or changed. To add them once it is idle, run again with --add-nvme-power-settings."
        _log "NVMe power settings: not asked (MoreBees in use: ${MB_IN_USE[*]}); not changed"
        return 0
    elif _nvme_ask "$model"; then
        reason="you answered yes"
    else
        info "The boot line was not changed. To add the settings later, run again with --add-nvme-power-settings."
        return 0
    fi
    # A change needs a restart: on an installed Pi, never while MoreBees runs.
    if [[ "$INSTALLED" == 1 ]] && _morebees_in_use; then
        warn "MoreBees is in use:"
        for found in "${MB_IN_USE[@]}"; do warn "  $found"; done
        refuse "The NVMe power settings ($NVME_MISSING) take effect only after a restart, which would end it." \
            "Let it finish, close MoreBees, and run this again. Nothing was changed."
    fi
    if _nvme_apply "$reason"; then
        _nvme_restart_stop
    fi
    _nvme_go_on_or_stop "The NVMe power settings were not added: $NVME_FAILED. The boot line ($f) was not changed." \
        "$reason" "$(_nvme_by_hand "$NVME_MISSING")"
}

# --- An installed standalone Pi ----------------------------------------------

detect_installed() {
    # Read-only: any one of these means an install was at least started here.
    # read_installed_facts then tells a finished install from an unfinished one.
    if [[ -e "$HOME/rso" || -L "$HOME/rso" || -e "$ROLE_FILE" \
          || -e "$BIN_DIR/rso-standalone-gui" || -e "$BIN_DIR/renandstimpi-gui" ]]; then
        INSTALLED=1
    fi
}

check_installed_role() {
    [[ -e "$ROLE_FILE" ]] || return 0
    local role=""
    role="$(head -n 1 "$ROLE_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$role" == standalone ]] && return 0
    refuse "This computer is set up as a MoreBees ${role:-(unnamed role)} ($ROLE_FILE)." \
           "The standalone installer does not reinstall it. Nothing was changed."
}

_baked_install_dir() {
    # The install folder that installers/standalone/modules/55-cli.sh baked into
    # the renandstimpi-gui wrapper, as the line:  cd "<dir>" || exit 1
    local wrapper="$BIN_DIR/renandstimpi-gui" line
    [[ -f "$wrapper" && -r "$wrapper" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            'cd "'*'" || exit 1')
                line="${line#cd \"}"
                printf '%s\n' "${line%\" || exit 1}"
                return 0
                ;;
        esac
    done < "$wrapper"
    return 1
}

read_installed_facts() {
    local where="none"
    if [[ -d "$CUR/.git" ]]; then
        CUR_OK=1
        O="$(git -C "$CUR" describe --tags --exact-match 2>/dev/null || true)"
        where="$(readlink "$CUR" 2>/dev/null || echo "$CUR")"
    fi
    INSTALL_DIR="$(_baked_install_dir || true)"
    # The installer's own rule (install_standalone.sh, refuse_if_provisioned):
    # a Pi is provisioned once ~/rso/current exists and /etc/rso/role says
    # standalone, which phase 70 writes at its cutover. Other markers without
    # both are an install that stopped part way. check_installed_role has
    # already refused any other role.
    if [[ "$CUR_OK" == 1 && -e "$ROLE_FILE" ]]; then
        PROVISIONED=1
    fi
    _log "installed: ~/rso/current -> $where, tag ${O:-none}, install folder ${INSTALL_DIR:-none}, provisioned $PROVISIONED"
}

_args_have() {
    # _args_have <flag> <args...>
    local want="$1" a
    shift
    for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done
    return 1
}

_has_only() {
    local a
    for a in "$@"; do
        case "$a" in --only|--only=*) return 0 ;; esac
    done
    return 1
}

_has_info_flag() {
    # --help or --dry-run: the installer only prints, needing no root and no network.
    local a
    for a in "$@"; do
        case "$a" in --help|-h|--dry-run) return 0 ;; esac
    done
    return 1
}

installed_info_run() {
    # --help or --dry-run without --only on a provisioned Pi: the installed
    # release's installer answers as the operator, before any target is chosen,
    # any sign-in or any copy. Its status is passed on as it is, but for a 5,
    # which only the NVMe restart ends a run with: _on_exit makes it 1.
    BOOTSTRAP_STEP="installed-info"
    local rc=0
    [[ -f "$CUR/$STANDALONE_ENTRY" ]] || refuse \
        "The installed release in ~/rso/current has no standalone installer to ask." \
        "Nothing was changed."
    info "asking the installed release's installer (${O:-untagged}, ~/rso/current); nothing is changed."
    echo || true
    _log "running: bash $CUR/$STANDALONE_ENTRY $*"
    bash "$CUR/$STANDALONE_ENTRY" "$@" || rc=$?
    _log "installer exit status: $rc"
    exit "$rc"
}

_only_list() {
    # The --only value(s) among the arguments, comma-joined.
    local prev="" a out=""
    for a in "$@"; do
        [[ "$prev" == "--only" ]] && out="$out,$a"
        case "$a" in --only=*) out="$out,${a#--only=}" ;; esac
        prev="$a"
    done
    printf '%s' "${out#,}"
}

_needs_busy_check() {
    # Phases that stop or replace what a running MoreBees uses, by number or
    # name (the installer's phase table): 20 daqhats, 70 blue_green,
    # 75 camera, 90 hardware.
    local list="$1" item IFS=,
    for item in $list; do
        case "$item" in 20|daqhats|70|blue_green|75|camera|90|hardware) return 0 ;; esac
    done
    return 1
}

# _run_with_timeout <seconds> <command...>: status 124 when it overran.
_run_with_timeout() {
    local secs="$1" pid ticks=0
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$ticks" -ge $((secs * 10)) ]]; then
            kill -TERM "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

_rigcam_busy() {
    # Prints why the camera recorder is busy and returns 0; returns 1 when it
    # is not running or reports no open session. It does not answer its status
    # request while it finishes a session, so silence counts as busy.
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet rigcam 2>/dev/null || return 1
    local tree="" py="python3" name="cam0" out rc=0 line
    if [[ "$CUR_OK" == 1 ]]; then
        tree="$CUR"
    elif [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]]; then
        tree="$INSTALL_DIR"
    fi
    if [[ -x "$HOME/rso/shared/venv/bin/python" ]]; then
        py="$HOME/rso/shared/venv/bin/python"
    elif [[ -n "$INSTALL_DIR" && -x "$INSTALL_DIR/venv/bin/python" ]]; then
        py="$INSTALL_DIR/venv/bin/python"
    fi
    if [[ -r "$RIGCAM_ENV" ]]; then
        line="$(sed -n 's/^RIGCAM_NAME=//p' "$RIGCAM_ENV" | tail -n 1 | tr -d "\"' ")"
        [[ -z "$line" ]] || name="$line"
    fi
    if [[ -z "$tree" ]]; then
        echo "the camera recorder (rigcam) is running, and no MoreBees release here can ask whether it has a session open"
        return 0
    fi
    out="$(mktemp "${TMPDIR:-/tmp}/morebees-rigcam.XXXXXX")" || {
        echo "the camera recorder (rigcam) is running, and its status could not be read"
        return 0
    }
    # PYTHONDONTWRITEBYTECODE: asking must not write caches into the release.
    ( cd "$tree" || exit 1
      export PYTHONPATH="$tree" PYTHONDONTWRITEBYTECODE=1
      _run_with_timeout "$RIGCAM_TIMEOUT" "$py" -m renandstimpi.modules.camera.ctl \
          status --json --name "$name" </dev/null ) >"$out" 2>&1 || rc=$?
    _log "rigcam status (exit $rc): $(tr '\n' ' ' < "$out" | cut -c1-300)"
    if [[ "$rc" == 0 ]] && grep -q '"session_active": *false' "$out"; then
        rm -f "$out"
        return 1
    fi
    if [[ "$rc" == 0 ]] && grep -q '"session_active": *true' "$out"; then
        echo "the camera recorder (rigcam) has a session open"
    elif [[ "$rc" == 124 ]]; then
        echo "the camera recorder (rigcam) did not answer its status request within $RIGCAM_TIMEOUT s"
    elif [[ "$rc" == 0 ]]; then
        echo "the camera recorder (rigcam) did not say whether a session is open"
    else
        echo "the camera recorder (rigcam) did not answer its status request (exit status $rc)"
    fi
    rm -f "$out"
    return 0
}

# _morebees_in_use: true when a MoreBees window, a task, the hardware setup or a
# camera session is running; MB_IN_USE lists what was found. Read-only.
_morebees_in_use() {
    local line pid args reason
    MB_IN_USE=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        pid="${line%%[[:space:]]*}"
        args="${line#"$pid"}"
        args="${args#"${args%%[![:space:]]*}"}"
        [[ -n "$pid" && "$pid" != "$$" ]] || continue
        case "$args" in
            # The recorder is judged by its own status, below.
            *renandstimpi.modules.camera.service*|*renandstimpi.modules.camera.ctl*) ;;
            *renandstimpi.gui_launcher*|*scripts/runtime/launch.sh*|*renandstimpi.tasks*|*"-m renandstimpi"*)
                MB_IN_USE+=("pid $pid: ${args:0:110}") ;;
        esac
    done < <(ps -Ao pid=,args= 2>/dev/null || true)
    if reason="$(_rigcam_busy)"; then
        MB_IN_USE+=("$reason")
    fi
    [[ ${#MB_IN_USE[@]} -gt 0 ]]
}

busy_check() {
    # Read-only. Installers released before the app's reinstall feature have no
    # busy guard of their own, so an --only run of a phase that stops or
    # replaces what MoreBees uses refuses here while MoreBees runs.
    BOOTSTRAP_STEP="busy-check"
    local f
    _morebees_in_use || return 0
    warn "MoreBees is in use:"
    for f in "${MB_IN_USE[@]}"; do warn "  $f"; done
    refuse "Stop it or let it finish, close MoreBees, and run this again. Nothing was changed."
}

installed_only_select() {
    # The installer an --only run uses on an installed Pi: the installed
    # release's own, else the install folder's at its current commit.
    if [[ "$CUR_OK" == 1 && -f "$CUR/$STANDALONE_ENTRY" ]]; then
        ONLY_INSTALLER="$CUR/$STANDALONE_ENTRY"
        ONLY_REF="$O"
        ONLY_FROM="the installed release (${O:-untagged}, ~/rso/current)"
        return 0
    fi
    if [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR/.git" && -f "$INSTALL_DIR/$STANDALONE_ENTRY" ]]; then
        ONLY_INSTALLER="$INSTALL_DIR/$STANDALONE_ENTRY"
        # Nothing is checked out; its own tag keeps phase 30 where it is.
        ONLY_REF="$(git -C "$INSTALL_DIR" describe --tags --exact-match 2>/dev/null || true)"
        ONLY_FROM="the install folder $INSTALL_DIR, at its current commit"
        return 0
    fi
    return 1
}

installed_only_run() {
    # --only on an installed Pi: no sign-in, no clone, no change to ~/projects
    # or ~/rso. The installer's --only also skips its re-provision refusal.
    BOOTSTRAP_STEP="installed-only"
    local env_args=() rc=0
    REF="$ONLY_REF"
    INSTALLER_LOG="$STANDALONE_LOG"
    [[ -z "$ONLY_REF" ]] || env_args+=("RSO_GIT_REF=$ONLY_REF")
    if [[ -n "$INSTALL_DIR" ]]; then
        env_args+=("RSO_INSTALL_DIR=$INSTALL_DIR")
    else
        warn "no install folder is recorded in $BIN_DIR/renandstimpi-gui; the installer uses its default."
    fi
    echo
    info "re-running --only $(_only_list "$@") with the installer of $ONLY_FROM"
    info "(no GitHub sign-in; sudo password may be requested)…"
    echo
    _run_installer_cmd sudo ${env_args[@]+"${env_args[@]}"} bash "$ONLY_INSTALLER" "$@" || rc=$?
    run_end "$rc"
}

# semver_cmp <a> <b>: sets SEMVER_CMP to -1, 0 or 1 by SemVer 2.0 precedence for
# vMAJOR.MINOR.PATCH[-PRE] tags, and returns 1 when either is not such a tag.
# Numeric parts compare as numbers, a pre-release ranks below its release, and
# numeric identifiers compare as numbers (rc.2 < rc.10).
semver_cmp() {
    SEMVER_CMP=""
    local LC_ALL=C re='^v([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?$'
    local a1 a2 a3 ap b1 b2 b3 bp k=0 n m x y
    local -a pa pb
    [[ "$1" =~ $re ]] || return 1
    a1="${BASH_REMATCH[1]}"; a2="${BASH_REMATCH[2]}"; a3="${BASH_REMATCH[3]}"; ap="${BASH_REMATCH[5]}"
    [[ "$2" =~ $re ]] || return 1
    b1="${BASH_REMATCH[1]}"; b2="${BASH_REMATCH[2]}"; b3="${BASH_REMATCH[3]}"; bp="${BASH_REMATCH[5]}"
    for k in 1 2 3; do
        case "$k" in
            1) x="$a1"; y="$b1" ;;
            2) x="$a2"; y="$b2" ;;
            3) x="$a3"; y="$b3" ;;
        esac
        if ((10#$x < 10#$y)); then SEMVER_CMP=-1; return 0; fi
        if ((10#$x > 10#$y)); then SEMVER_CMP=1; return 0; fi
    done
    if [[ -z "$ap" && -z "$bp" ]]; then SEMVER_CMP=0; return 0; fi
    if [[ -z "$ap" ]]; then SEMVER_CMP=1; return 0; fi
    if [[ -z "$bp" ]]; then SEMVER_CMP=-1; return 0; fi
    IFS=. read -r -a pa <<< "$ap"
    IFS=. read -r -a pb <<< "$bp"
    n=${#pa[@]}; m=${#pb[@]}; k=0
    while ((k < n && k < m)); do
        x="${pa[k]}"; y="${pb[k]}"
        if [[ "$x" != "$y" ]]; then
            if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
                if ((10#$x < 10#$y)); then SEMVER_CMP=-1; else SEMVER_CMP=1; fi
            elif [[ "$x" =~ ^[0-9]+$ ]]; then
                SEMVER_CMP=-1          # numeric identifiers rank below others
            elif [[ "$y" =~ ^[0-9]+$ ]]; then
                SEMVER_CMP=1
            elif [[ "$x" < "$y" ]]; then
                SEMVER_CMP=-1
            else
                SEMVER_CMP=1
            fi
            return 0
        fi
        k=$((k + 1))
    done
    if ((n < m)); then SEMVER_CMP=-1; elif ((n > m)); then SEMVER_CMP=1; else SEMVER_CMP=0; fi
    return 0
}

_newest_tags() {
    # _newest_tags <count>: up to <count> release tags from REMOTE_TAGS, newest first.
    local count="$1" chosen=" " best tag i=0
    while ((i < count)); do
        best=""
        while IFS= read -r tag; do
            [[ -n "$tag" && "$chosen" != *" $tag "* ]] || continue
            semver_cmp "$tag" "$tag" || continue
            if [[ -z "$best" ]]; then
                best="$tag"
            elif semver_cmp "$tag" "$best" && [[ "$SEMVER_CMP" == 1 ]]; then
                best="$tag"
            fi
        done <<< "$REMOTE_TAGS"
        [[ -n "$best" ]] || break
        printf '%s\n' "$best"
        chosen="$chosen$best "
        i=$((i + 1))
    done
}

signin_fallback() {
    # The Pi's own origin and deploy key did not answer: sign in as on a new
    # Pi. The deploy key is then provisioned again, before the hand-off.
    [[ "$SIGNIN_REACHED" == 1 ]] && return 0
    warn "this Pi's deploy key could not reach $APP_SLUG; signing in to GitHub instead."
    ensure_prereqs
    github_signin
}

_remote_urls() {
    # Where this Pi fetches from without a sign-in: its own origin, then the
    # deploy-key alias when the key exists and origin is something else.
    if [[ -n "$SRC_URL" ]]; then
        printf '%s\n' "$SRC_URL"
    fi
    if [[ "$SRC_URL" != "git@$DEPLOY_ALIAS:"* && -f "$DEPLOY_KEY" ]]; then
        printf '%s\n' "git@$DEPLOY_ALIAS:$APP_SLUG.git"
    fi
}

# _ls_remote <sign-in allowed: 0|1> <tags|refs> [pattern...]: git ls-remote on
# the app repository; fills LS_OUT. Returns 1 when nothing answered.
_ls_remote() {
    local allow="$1" mode="$2" url
    shift 2
    local opts=()
    [[ "$mode" != tags ]] || opts=(--tags)
    for url in $(_remote_urls); do
        if LS_OUT="$(_git_net ls-remote ${opts[@]+"${opts[@]}"} "$url" "$@" 2>/dev/null)"; then
            if [[ "$url" == "git@$DEPLOY_ALIAS:"* ]]; then SSH_VERIFIED=1; fi
            return 0
        fi
    done
    [[ "$allow" == 1 ]] || return 1
    signin_fallback
    LS_OUT="$(GIT_TERMINAL_PROMPT=0 git ls-remote ${opts[@]+"${opts[@]}"} "https://github.com/$APP_SLUG.git" "$@" 2>/dev/null)"
}

_fill_remote_tags() {
    # _fill_remote_tags <sign-in allowed: 0|1>: REMOTE_TAGS, one tag per line.
    [[ -z "$REMOTE_TAGS" ]] || return 0
    _ls_remote "$1" tags 'v*' || return 1
    REMOTE_TAGS="$(printf '%s\n' "$LS_OUT" | sed 's#.*refs/tags/##' | grep -v '\^{}$' || true)"
}

_ls_has() {
    # _ls_has <ref>: LS_OUT lists exactly this ref.
    printf '%s\n' "$LS_OUT" | awk -v r="$1" '$2 == r { f = 1 } END { exit !f }'
}

_ref_kind() {
    # _ref_kind <ref>: REF_KIND = tag, branch, missing_v (v<ref> exists) or missing.
    local t="$1"
    REF_KIND=missing
    if [[ -n "$SRC" ]] && git -C "$SRC" show-ref --verify --quiet "refs/tags/$t"; then
        REF_KIND=tag
        return 0
    fi
    _ls_remote 1 refs "refs/tags/$t" "refs/heads/$t" "refs/tags/v$t" \
        || die "could not reach $APP_SLUG to look up RSO_GIT_REF=$t (network problem? try again)."
    if _ls_has "refs/tags/$t"; then
        REF_KIND=tag
    elif _ls_has "refs/heads/$t"; then
        REF_KIND=branch
    elif _ls_has "refs/tags/v$t"; then
        REF_KIND=missing_v
    fi
}

_installer_can_reinstall() {
    # _installer_can_reinstall <tree>: its standalone installer lists --reinstall
    # in --help, which needs no root and changes nothing.
    local entry="$1/$STANDALONE_ENTRY" out
    [[ -f "$entry" ]] || return 1
    out="$(_run_with_timeout 30 bash "$entry" --help </dev/null 2>&1 || true)"
    printf '%s\n' "$out" | grep -qE '^[[:space:]]*--reinstall([[:space:]=]|$)'
}

reinstall_guidance_card() {
    local tags installed="MoreBees is installed on this Pi (its version could not be read)."
    [[ -z "$O" ]] || installed="MoreBees $O is installed on this Pi."
    warn "$installed Reinstalling it needs a release"
    warn "whose installer can keep or delete your data (the first is planned for v0.5.1)."
    warn "Run again with RSO_GIT_REF=<a newer tag> when one exists."
    warn "To repair one part without reinstalling: --only <phase>."
    warn "Your recorded sessions are in ~/rso/shared/data: never remove ~/rso."
    if _fill_remote_tags 0; then
        tags="$(_newest_tags 5 | tr '\n' ' ')"
        warn "Newest release tags: ${tags:-none found}"
    else
        warn "(The newest release tags could not be listed: the deploy key did not answer.)"
    fi
    refuse "Nothing was changed."
}

resolve_reinstall_target() {
    BOOTSTRAP_STEP="reinstall-target"
    local t="${RSO_GIT_REF:-}" best="" tag
    if [[ -n "$t" ]]; then
        if [[ "$t" =~ ^[0-9a-f]{7,40}$ ]]; then
            refuse "RSO_GIT_REF=$t looks like a commit: a reinstall installs release tags only. Nothing was changed."
        fi
        _ref_kind "$t"
        case "$REF_KIND" in
            tag) ;;
            branch) refuse "RSO_GIT_REF=$t is a branch: a reinstall installs release tags only. Nothing was changed." ;;
            missing_v) refuse "RSO_GIT_REF=$t does not exist. Did you mean v$t? Nothing was changed." ;;
            *) refuse "RSO_GIT_REF=$t does not exist on $APP_SLUG (release tags look like vX.Y.Z). Nothing was changed." ;;
        esac
        if [[ -n "$O" ]] && semver_cmp "$t" "$O"; then
            if [[ "$SEMVER_CMP" == -1 ]] && ! _args_have --allow-older-release "$@"; then
                refuse "RSO_GIT_REF=$t is older than the installed $O." \
                       "To install it anyway, run again with --allow-older-release. Nothing was changed."
            fi
        elif [[ -n "$O" ]]; then
            _log "not compared by version: $t and $O are not both vX.Y.Z[-pre] tags"
        fi
        REF="$t"
        info "reinstall target: $REF (RSO_GIT_REF)"
        return 0
    fi
    if [[ -n "$O" ]] && _installer_can_reinstall "$CUR"; then
        REF="$O"
        info "reinstall target: $REF, the installed release (its installer can reinstall)"
        return 0
    fi
    _fill_remote_tags 1 || die "could not list release tags on $APP_SLUG (network problem? try again)."
    while IFS= read -r tag; do
        [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        if [[ -n "$O" ]] && semver_cmp "$tag" "$O" && [[ "$SEMVER_CMP" != 1 ]]; then
            continue    # never older than the installed release, nor the same
        fi
        if [[ -z "$best" ]]; then
            best="$tag"
        elif semver_cmp "$tag" "$best" && [[ "$SEMVER_CMP" == 1 ]]; then
            best="$tag"
        fi
    done <<< "$REMOTE_TAGS"
    if [[ -z "$best" ]]; then
        reinstall_guidance_card
    fi
    REF="$best"
    info "reinstall target: $REF, the newest release${O:+ newer than $O}"
}

prepare_build_clone() {
    # The target's installer, from a temporary clone outside ~/projects and
    # ~/rso: a local copy of the installed release (no network), plus the
    # target tag through the Pi's own origin when the copy lacks it.
    BOOTSTRAP_STEP="reinstall-copy"
    mkdir -p "$HOME/.cache/morebees" || die "could not create $HOME/.cache/morebees."
    BUILD="$(mktemp -d "$HOME/.cache/morebees/build.XXXXXX")" \
        || die "could not create a temporary folder under $HOME/.cache/morebees."
    _log "temporary copy: $BUILD (from ${SRC:-the network})"
    if [[ -n "$SRC" ]]; then
        info "preparing the $REF installer in a temporary local copy of ${SRC}…"
        git clone --quiet --no-checkout "$SRC" "$BUILD" || die "could not make a local copy of $SRC."
        if [[ -n "$SRC_URL" ]]; then
            git -C "$BUILD" remote set-url origin "$SRC_URL"
        else
            git -C "$BUILD" remote remove origin 2>/dev/null || true
        fi
    else
        git init --quiet "$BUILD" || die "could not prepare $BUILD."
        if [[ -f "$DEPLOY_KEY" ]]; then
            git -C "$BUILD" remote add origin "git@$DEPLOY_ALIAS:$APP_SLUG.git"
        fi
    fi
    if ! git -C "$BUILD" rev-parse --verify --quiet "refs/tags/$REF^{commit}" >/dev/null; then
        info "fetching ${REF}…"
        if [[ -n "$(_origin_url "$BUILD")" ]] \
                && _git_net -C "$BUILD" fetch --quiet origin "refs/tags/$REF:refs/tags/$REF" 2>/dev/null; then
            if [[ "$(_origin_url "$BUILD")" == "git@$DEPLOY_ALIAS:"* ]]; then
                SSH_VERIFIED=1
            fi
        else
            signin_fallback
            GIT_TERMINAL_PROMPT=0 git -C "$BUILD" fetch --quiet "https://github.com/$APP_SLUG.git" \
                "refs/tags/$REF:refs/tags/$REF" || die "could not fetch $REF from $APP_SLUG."
        fi
    fi
    git -C "$BUILD" checkout --quiet --detach "refs/tags/$REF" \
        || die "could not check out $REF in $BUILD."
}

installed_full_run() {
    # A full run on an installed Pi: the target release's installer, run from
    # BUILD, asks what to do with the data. Here the bootstrap asks nothing and
    # changes nothing in ~/projects, the install folder or ~/rso; the NVMe check
    # before it (nvme_power_check, in main) may ask its question and add the
    # settings to the boot line, before the release is chosen.
    if [[ "$CUR_OK" == 1 ]]; then
        SRC="$CUR"
    elif [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR/.git" ]]; then
        SRC="$INSTALL_DIR"
    fi
    if [[ -n "$SRC" ]]; then
        SRC_URL="$(_origin_url "$SRC")"
    fi
    resolve_reinstall_target "$@"
    prepare_build_clone
    BOOTSTRAP_STEP="reinstall-check"
    if ! _installer_can_reinstall "$BUILD"; then
        reinstall_guidance_card
    fi
    if [[ "$SIGNIN_REACHED" == 1 ]]; then
        # The deploy key failed earlier in this run: provision it as on a new
        # Pi, against the temporary copy only.
        local rerun="bash <the release>/scripts/setup_terminal_deploy_key.sh"
        if [[ -f "$CUR/scripts/setup_terminal_deploy_key.sh" ]]; then
            rerun="bash $CUR/scripts/setup_terminal_deploy_key.sh --repo $CUR"
        fi
        provision_deploy_key "$BUILD" "$rerun"
        if [[ "$SSH_VERIFIED" == 1 ]]; then
            sign_out
        fi
    fi
    INSTALLER_LOG="$STANDALONE_LOG"
    echo
    info "handing off to the MoreBees $REF installer, run from the temporary copy; it asks"
    info "what to do with the data on this Pi (sudo password may be requested)…"
    echo
    local rc=0
    # PYTHONDONTWRITEBYTECODE: the installer runs as root from BUILD, and root's
    # caches there would keep the operator from removing it (_remove_build).
    _run_installer_cmd sudo RSO_GIT_REF="$REF" MB_REINSTALL_SOURCE=bootstrap PYTHONDONTWRITEBYTECODE=1 \
        bash "$BUILD/$STANDALONE_ENTRY" "$@" || rc=$?
    finish_auth
    run_end "$rc"
}

# --- Exit handling -------------------------------------------------------------

# shellcheck disable=SC2329  # run by a trap
_on_signal() {
    # Bash runs this once the foreground command has returned. The installer
    # reports an interruption itself (129, 130 or 143), and run_end says so.
    [[ "$IN_INSTALLER" == 1 ]] && return 0
    exit "$1"
}
# _bootstrap_traps: the run's signal traps, set once in main and again after a
# failed NVMe change, whose move nothing may interrupt.
_bootstrap_traps() {
    trap '_on_signal 129' HUP
    trap '_on_signal 130' INT
    trap '_on_signal 143' TERM
}

# shellcheck disable=SC2329  # run by a trap
_on_exit() {
    # Single EXIT trap, armed before the sign-in: remove the temporary copy,
    # keep the deploy-key origin (F14), tell the operator about a session left
    # behind on an early death, and name the log.
    local rc=$?
    set +e
    trap '' HUP INT TERM
    _remove_build
    _nvme_remove_staged
    [[ -z "$APP_DIR" ]] || _ensure_ssh_origin
    if [[ "$rc" -ne 0 && "$SIGNIN_REACHED" == 1 && "$AUTH_FINISHED" == 0 && "$SIGNED_OUT" == 0 ]] \
            && command -v gh >/dev/null 2>&1 \
            && gh auth status --hostname github.com >/dev/null 2>&1; then
        warn "this run ended early; your GitHub session is still signed in on this box."
        warn "Remove it with: gh auth logout --hostname github.com"
        warn "(its token stays valid on GitHub until revoked: https://github.com/settings/applications)"
    fi
    # 5 means the NVMe restart and nothing else: any other 5, such as a failing
    # command's status under set -e, ends the run with 1 instead.
    if [[ "$rc" == 5 && "$NVME_RESTART_EXIT" != 1 ]]; then
        echo -e "${RED}[bootstrap]${NC} a step ended with status 5, which only the NVMe restart may end a run with, so the run ends with 1." >&2 || true
        _log "exit status 5 was not the NVMe restart, so the run ends with 1"
        _failure_report
        rc=1
    fi
    if [[ -n "$LOG_FILE" ]]; then
        _log "bootstrap exit status: $rc"
        info "Bootstrap log: $LOG_FILE"
    fi
    exit "$rc"
}

# shellcheck disable=SC2329  # run by a trap
_remove_build() {
    # The temporary copy, and only it: a folder mktemp made directly under
    # ~/.cache/morebees. The installer ran as root from it, so when the
    # operator cannot remove it, root's files are inside and sudo removes it.
    [[ -n "$BUILD" && -d "$BUILD" ]] || return 0
    local base="$HOME/.cache/morebees/build." rest
    rest="${BUILD#"$base"}"
    if [[ "$rest" == "$BUILD" || -z "$rest" || "$rest" == */* ]]; then
        _log "temporary copy not removed: $BUILD is not a folder made under ~/.cache/morebees"
        return 0
    fi
    rm -rf "$BUILD" 2>/dev/null
    if [[ ! -e "$BUILD" ]]; then
        _log "temporary copy removed: $BUILD"
        return 0
    fi
    # sudo -n: this runs on exit, often long after the last sudo, and must never
    # stop to ask for a password; the warning below gives the command instead.
    if sudo -n rm -rf -- "$BUILD" 2>/dev/null && [[ ! -e "$BUILD" ]]; then
        _log "temporary copy removed with sudo (it held files owned by root): $BUILD"
    else
        warn "could not remove the temporary copy $BUILD; remove it with: sudo rm -rf -- $BUILD"
    fi
}

# shellcheck disable=SC2329  # run by a trap
_nvme_remove_staged() {
    # A run stopped while the boot line was changing: the new line's temporary
    # files go, the one in the boot folder with sudo -n, because nothing may ask
    # for a password on the way out. The boot line itself is either the old one
    # or the new one: the move is a single rename.
    if [[ -n "$NVME_STAGED" && -e "$NVME_STAGED" ]]; then
        if sudo -n rm -f -- "$NVME_STAGED" </dev/null 2>/dev/null && [[ ! -e "$NVME_STAGED" ]]; then
            _log "NVMe power settings: temporary file removed: $NVME_STAGED"
        else
            warn "could not remove $NVME_STAGED; remove it with: sudo rm -f -- $NVME_STAGED"
        fi
    fi
    NVME_STAGED=""
    if [[ -n "$NVME_WANT" ]]; then
        rm -f -- "$NVME_WANT" 2>/dev/null || true
        NVME_WANT=""
    fi
}

# shellcheck disable=SC2329  # run by a trap
_ensure_ssh_origin() {
    # The wizard's installer may re-clone the repo (operator answers "yes" to
    # "Remove and re-clone?"), which resets origin to HTTPS. Guarantee the box
    # ends with the deploy-key SSH origin no matter how the run exits -- else
    # unattended updates break once the gh session is gone (F14, field-tested).
    # Only the checkout this run made: an installed Pi's folders are not touched.
    local repo="$APP_DIR"
    [[ -f "$DEPLOY_KEY" && -d "$repo/.git" ]] || return 0
    local want="git@$DEPLOY_ALIAS:$APP_SLUG.git"
    [[ "$(_origin_url "$repo")" == "$want" ]] && return 0
    info "restoring the deploy-key SSH origin (a re-clone had reset it)"
    git -C "$repo" remote set-url origin "$want" 2>/dev/null || true
}

new_install() {
    # First: a stop for a restart must come before the sign-in and the clone.
    nvme_power_check "$@"
    ensure_prereqs
    github_signin
    resolve_release_ref
    ensure_app_clone
    provision_deploy_key "$APP_DIR"
    if [[ "$ROLE" == "standalone" && "$SSH_VERIFIED" == 1 ]]; then
        # The standalone installer needs no GitHub credentials once origin is
        # the deploy key (its git runs through origin), so the token leaves now
        # rather than after the package installs that run as this account. The
        # terminal role keeps the old timing: the wizard may re-clone over https
        # with gh's credentials (rso_terminal_installer/modules/30-project_management.sh).
        sign_out
    fi
    local rc=0
    run_installer "$@" || rc=$?
    finish_auth
    run_end "$rc"
}

main() {
    echo
    echo "========================================"
    echo " MoreBees installer — many rigs, one hive"
    echo "========================================"
    echo

    [[ $(id -u) -ne 0 ]] || die "run as your normal user, not root -- it will sudo when needed."

    parse_role "$@"
    split_equals_forms                 # --only=<k> becomes --only <k>, the form every installer reads
    set -- "${ARGS[@]+"${ARGS[@]}"}"   # role flags consumed; forward the rest

    # Piped from curl, stdin is the pipe; reattach the real terminal so the
    # installer's prompts and the NVMe question work. The subshell probe keeps a
    # failed open (no controlling terminal) from killing the script.
    if [[ -t 0 ]]; then
        HAVE_TTY=1
    elif (exec <"$TTY_DEV") 2>/dev/null; then
        exec <"$TTY_DEV"
        HAVE_TTY=1
    fi

    log_init
    trap _on_exit EXIT   # before the sign-in: every exit cleans up and names the log
    _bootstrap_traps

    if [[ "$NVME_FORCE" == 1 && "$NVME_DECLINE" == 1 ]]; then
        refuse "--add-nvme-power-settings and --no-nvme-power-settings ask for opposite things; give one of them." \
            "Nothing was changed."
    fi

    if [[ "$ROLE" == "standalone" ]]; then
        detect_installed
        if [[ "$INSTALLED" == 1 ]]; then
            BOOTSTRAP_STEP="installed-pi"
            check_installed_role
            read_installed_facts
            if _has_only "$@" && _needs_busy_check "$(_only_list "$@")"; then
                busy_check
            fi
            if [[ "$PROVISIONED" == 1 ]]; then
                info "MoreBees is already installed on this Pi${O:+ ($O)}; the bootstrap changes nothing in ~/projects or ~/rso."
                if _has_only "$@"; then
                    [[ -z "${RSO_GIT_REF:-}" ]] \
                        || warn "RSO_GIT_REF is ignored with --only on an installed Pi: --only re-runs phases of the installed release."
                    installed_only_select || refuse \
                        "The installed release in ~/rso/current has no standalone installer to run --only with." \
                        "Nothing was changed."
                    # After every check that stops with nothing changed, before the hand-off.
                    nvme_power_check "$@"
                    installed_only_run "$@"
                fi
                if _has_info_flag "$@"; then
                    installed_info_run "$@"
                fi
                # Before the release is chosen: that may sign in or make a copy.
                nvme_power_check "$@"
                installed_full_run "$@"
            fi
            # Stopped before phase 70's cutover: the steps of a new Pi finish it,
            # as running the one-liner again always did.
            info "An unfinished MoreBees install was found; finishing it."
            if [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "$HOME/projects/RenAndStimPi" ]]; then
                warn "The unfinished install used $INSTALL_DIR; this run installs into ~/projects/RenAndStimPi."
            fi
        fi
    fi
    new_install "$@"
}

# exit on the SAME parsed line as main: with `curl | bash`, bash reads this
# script from stdin, and main() re-points stdin at the terminal for the
# prompts -- if anything had to be read after main returns, bash would sit
# waiting for "script" typed on the keyboard (field-tested hang).
main "$@"; exit $?
