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
# On a Raspberry Pi that already has MoreBees (standalone role), it signs in only
# when the Pi's own deploy key cannot fetch the release, and it never changes
# ~/projects or ~/rso. --only re-runs phases with the installed release's own
# installer; a full run hands off to the target release's installer, run from a
# temporary local copy, and that installer asks what to do with the data.
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
# Role flags are consumed here; every other arg is forwarded to the installer:
#   ... --standalone                           # single-rig Pi
#   ... --skip-taskpi --skip-ml --dev-mode     # terminal-only test box
#   ... --start-rig-id 01                      # full lab
#   ... --standalone --skip-phase 20           # Pi, skip the DAQ HAT lib
#
# Exit status: the installer's own (0 installed, 2 installed with problems,
# 3 stopped before installing with nothing changed, 4 reinstall undone,
# 129/130/143 interrupted); 1 when the bootstrap itself fails, with a failure
# report to paste.
#
# Log: ${XDG_STATE_HOME:-~/.local/state}/morebees/bootstrap-<date>-<pid>.log,
# mode 0600: the bootstrap's own messages only. The installer keeps its own log;
# copying its output here would turn off its live progress line.
#
# Test seams (the test suite points these into a sandbox): MB_BIN_DIR,
# MB_ROLE_FILE, MB_RIGCAM_ENV, MB_RIGCAM_TIMEOUT.
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
INSTALLED=0          # standalone role: a MoreBees install was found
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
model: $(tr -d '\0' </proc/device-tree/model 2>/dev/null || uname -m)
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
    printf '%s\n' "$report" >&2
    _log "$report"
}

die() {
    echo -e "${RED}[bootstrap]${NC} $*" >&2
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

log_init() {
    # The bootstrap's own record: its messages, the installer's command line and
    # exit status. Not a copy of the installer's output: teeing it would make the
    # installer's stderr a pipe, and its live progress line needs a terminal
    # (rso_terminal_installer/lib/ui.sh, mb_ui_init).
    local base="${XDG_STATE_HOME:-}" dir stamp file sum=""
    [[ "$base" == /* ]] || base="$HOME/.local/state"   # XDG: relative paths are invalid
    dir="$base/morebees"
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
    # Consume the role flags; everything else is forwarded untouched.
    local a
    for a in "$@"; do
        case "$a" in
            --standalone) ROLE="standalone" ;;
            --terminal)   ROLE="terminal" ;;
            *) ARGS+=("$a") ;;
        esac
    done

    if [[ -z "$ROLE" ]]; then
        # A Raspberry Pi cannot run the lab wizard (it provisions a Terminal
        # PC: PostgreSQL, the API service, the rig subnet), so defaulting to
        # it here would be a guaranteed-wrong install. Detect and say so.
        if grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
            ROLE="standalone"
            info "Raspberry Pi detected -- installing the single-rig standalone setup."
            info "Pass --terminal to install the lab wizard flow instead."
        else
            ROLE="terminal"
        fi
    fi
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
                | sudo tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
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
    echo -e "${RED}[bootstrap]${NC} $what stopped with status $rc -- see its output above." >&2
    _log "ERROR $what stopped with status $rc"
    _failure_report
}

# run_end <installer exit status>: say what the status means, then exit with it.
run_end() {
    local rc="$1" what="MoreBees${REF:+ $REF}"
    BOOTSTRAP_STEP="run-installer"
    echo
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
    exit "$rc"
}

# --- An installed standalone Pi ----------------------------------------------

detect_installed() {
    # Read-only: any one of these means MoreBees was installed here before.
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
    _log "installed: ~/rso/current -> $where, tag ${O:-none}, install folder ${INSTALL_DIR:-none}"
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

busy_check() {
    # Read-only. Installers released before the app's reinstall feature have no
    # busy guard of their own, so an --only run of a phase that stops or
    # replaces what MoreBees uses refuses here while MoreBees runs.
    BOOTSTRAP_STEP="busy-check"
    local findings=() line pid args reason f
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
                findings+=("pid $pid: ${args:0:110}") ;;
        esac
    done < <(ps -Ao pid=,args= 2>/dev/null || true)
    if reason="$(_rigcam_busy)"; then
        findings+=("$reason")
    fi
    [[ ${#findings[@]} -gt 0 ]] || return 0
    warn "MoreBees is in use:"
    for f in "${findings[@]}"; do warn "  $f"; done
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
    warn "whose installer can keep or delete your data (the first is planned for v0.5.0)."
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
            missing_v) refuse "RSO_GIT_REF=$t does not exist -- did you mean v$t? Nothing was changed." ;;
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
    # BUILD, asks what to do with the data. The bootstrap asks nothing and
    # changes nothing in ~/projects, the install folder or ~/rso.
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
    _run_installer_cmd sudo RSO_GIT_REF="$REF" MB_REINSTALL_SOURCE=bootstrap \
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

# shellcheck disable=SC2329  # run by a trap
_on_exit() {
    # Single EXIT trap, armed before the sign-in: remove the temporary copy,
    # keep the deploy-key origin (F14), tell the operator about a session left
    # behind on an early death, and name the log.
    local rc=$?
    set +e
    trap '' HUP INT TERM
    if [[ -n "$BUILD" && -d "$BUILD" ]]; then
        case "$BUILD" in "$HOME"/.cache/morebees/build.*) rm -rf "$BUILD" ;; esac
    fi
    [[ -z "$APP_DIR" ]] || _ensure_ssh_origin
    if [[ "$rc" -ne 0 && "$SIGNIN_REACHED" == 1 && "$AUTH_FINISHED" == 0 && "$SIGNED_OUT" == 0 ]] \
            && command -v gh >/dev/null 2>&1 \
            && gh auth status --hostname github.com >/dev/null 2>&1; then
        warn "this run ended early; your GitHub session is still signed in on this box."
        warn "Remove it with: gh auth logout --hostname github.com"
        warn "(its token stays valid on GitHub until revoked: https://github.com/settings/applications)"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        _log "bootstrap exit status: $rc"
        info "Bootstrap log: $LOG_FILE"
    fi
    return 0
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
    set -- "${ARGS[@]+"${ARGS[@]}"}"   # role flags consumed; forward the rest

    # Piped from curl, stdin is the pipe; reattach the real terminal so the
    # installer's prompts work. The subshell probe keeps a failed open (no
    # controlling terminal) from killing the script.
    if [[ ! -t 0 ]] && (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty
    fi

    log_init
    trap _on_exit EXIT   # before the sign-in: every exit cleans up and names the log
    trap '_on_signal 129' HUP
    trap '_on_signal 130' INT
    trap '_on_signal 143' TERM

    if [[ "$ROLE" == "standalone" ]]; then
        detect_installed
        if [[ "$INSTALLED" == 1 ]]; then
            BOOTSTRAP_STEP="installed-pi"
            check_installed_role
            read_installed_facts
            info "MoreBees is already installed on this Pi${O:+ ($O)}; the bootstrap changes nothing in ~/projects or ~/rso."
            if _has_only "$@"; then
                [[ -z "${RSO_GIT_REF:-}" ]] \
                    || warn "RSO_GIT_REF is ignored with --only on an installed Pi: --only re-runs phases of the installed release."
                if _needs_busy_check "$(_only_list "$@")"; then
                    busy_check
                fi
                if installed_only_select; then
                    installed_only_run "$@"
                fi
                info "no installed MoreBees release here to run --only from; installing as on a new Pi."
            else
                installed_full_run "$@"
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
