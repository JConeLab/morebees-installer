#!/usr/bin/env bash
#
# MoreBees — one-line bootstrap installer
#
#   curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh | bash
#
# Sets up MoreBees (RenAndStimPi) from one command. The app repository is
# PRIVATE, so this script first signs you in to GitHub with your own account
# (a one-time browser device code — no tokens to paste), clones the latest
# release, provisions a read-only DEPLOY KEY for unattended updates, and hands
# off to the installer for this box. Your account is signed back out at the end.
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
#   RSO_GIT_REF    tag/branch/SHA to install (default: latest stable vX.Y.Z)
#   GH_TOKEN       pre-issued token for fully headless installs (skips the
#                  browser step; needs read access to the app repo)
#
# Role flags are consumed here; every other arg is forwarded to the installer:
#   ... | bash -s -- --standalone                           # single-rig Pi
#   ... | bash -s -- --skip-taskpi --skip-ml --dev-mode     # terminal-only test box
#   ... | bash -s -- --start-rig-id 01                      # full lab
#   ... | bash -s -- --standalone --skip-phase 20           # Pi, skip the DAQ HAT lib
#
# This file contains no secrets. Everything below runs inside main(), called
# on the last line, so a truncated download can never execute half a script.
set -Eeuo pipefail

APP_SLUG="${RSO_APP_REPO:-JConeLab/RenAndStimPi}"
DID_LOGIN=0
SSH_VERIFIED=0
APP_DIR=""
ROLE=""          # terminal | standalone -- resolved by parse_role
ARGS=()          # everything left after the role flags are consumed
STANDALONE_ENTRY="installers/standalone/install_standalone.sh"

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${BLUE}[bootstrap]${NC} $*"; }
ok()   { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*" >&2; }
die()  { echo -e "${RED}[bootstrap]${NC} $*" >&2; exit 1; }

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
    local missing=()
    for cmd in git curl; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "installing prerequisites: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y --no-install-recommends "${missing[@]}"
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
            sudo apt-get update -qq
            sudo apt-get install -y gh
        fi
    fi
}

github_signin() {
    if gh auth status --hostname github.com >/dev/null 2>&1; then
        info "already signed in to GitHub -- reusing that session"
    else
        echo
        info "One-time GitHub sign-in: a code will appear below."
        info "Open the shown URL in ANY browser (your phone works), enter the"
        info "code, and authorize with the GitHub account that has access to"
        info "$APP_SLUG."
        echo
        # Always print the sign-in URL instead of launching a local browser.
        # Headless boxes hit the snapd/xdg-open wall (field-found 2026-07-27);
        # a DESKTOP Pi is no better: gh opened the rig's own Chromium, which
        # flooded the terminal with its stderr (--no-decommit-pooled-pages
        # spam, Vulkan warnings) and stole the screen (field-found
        # 2026-09-04). The prompt already says any device's browser works.
        # An operator who really wants a local open can export BROWSER.
        local browser_env=()
        if [[ -z "${BROWSER:-}" ]]; then
            info "(the sign-in URL is printed below -- open it on any device)"
            browser_env=(env BROWSER=echo)
        fi
        "${browser_env[@]}" gh auth login --hostname github.com --git-protocol https --web \
            || die "GitHub sign-in failed. Your account needs access to $APP_SLUG."
        DID_LOGIN=1
    fi
    # Let plain git use gh's credentials (the installer clones over https).
    gh auth setup-git --hostname github.com
    # Fail early if the account cannot see the app repo.
    GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "https://github.com/$APP_SLUG.git" HEAD >/dev/null 2>&1 \
        || die "this GitHub account cannot access $APP_SLUG -- ask an admin for read access."
    ok "GitHub access to $APP_SLUG confirmed"
}

resolve_release_ref() {
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
        GIT_TERMINAL_PROMPT=0 git clone --progress "https://github.com/$APP_SLUG.git" "$APP_DIR"
        # origin/<ref> first: a bare branch name here trips git's DWIM
        # local-branch creation, which is incompatible with --detach
        # ("fatal: '--detach' cannot be used with '-b/-B/--orphan'",
        # field-found 2026-07-24 on the first branch-ref fresh install).
        GIT_TERMINAL_PROMPT=0 git -C "$APP_DIR" checkout --quiet --detach "origin/$REF" 2>/dev/null \
            || GIT_TERMINAL_PROMPT=0 git -C "$APP_DIR" checkout --quiet --detach "$REF"
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
   Install a newer release, e.g.:  ... | bash -s -- --standalone RSO_GIT_REF=vX.Y.Z
   or run the lab wizard flow instead with --terminal."
    else
        [[ -f "$APP_DIR/rso_core/tools/rso_deploy_wizard.sh" ]] \
            || die "lab wizard missing from $REF."
    fi
}

run_installer() {
    echo
    if [[ "$ROLE" == "standalone" ]]; then
        info "handing off to the MoreBees standalone-Pi installer (sudo password may be requested)…"
        echo
        # RSO_INSTALL_DIR points the installer at the checkout we already made:
        # without it phase 30 would clone the repo a SECOND time (~600 MB on a
        # Pi's SD card). The blue-green layout is adopted from this tree, after
        # which the app runs from ~/rso/current and this location is incidental.
        # Run as a child (NOT exec): we still sign the operator out afterwards.
        sudo RSO_GIT_REF="$REF" RSO_INSTALL_DIR="$APP_DIR" \
            bash "$APP_DIR/$STANDALONE_ENTRY" "$@" \
            || die "the standalone installer reported an error -- see its output above."
    else
        info "handing off to the MoreBees lab setup wizard (sudo password may be requested)…"
        echo
        sudo RSO_GIT_REF="$REF" bash "$APP_DIR/rso_core/tools/rso_deploy_wizard.sh" "$@" \
            || die "the lab wizard reported an error -- see its output above."
    fi
}

provision_deploy_key() {
    # Give the box its own least-privilege, read-only SSH deploy key so updates
    # never depend on a person's account -- equally true for a standalone Pi,
    # whose in-app update pill runs `git ls-remote` against origin. Requires the
    # signed-in account to be a repo ADMIN to auto-register; otherwise the
    # public key is printed for an admin to add.
    local repo_dir="$HOME/projects/RenAndStimPi"
    local setup="$repo_dir/scripts/setup_terminal_deploy_key.sh"
    local pub="$HOME/.ssh/rso_deploy_ed25519.pub"

    [[ -d "$repo_dir/.git" ]] || return 0   # clone missing (should not happen)
    if [[ ! -f "$setup" ]]; then
        warn "this release has no deploy-key setup script -- updates will use your GitHub session instead."
        return 0
    fi

    echo
    info "provisioning the unattended-update deploy key…"
    if bash "$setup"; then
        SSH_VERIFIED=1
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
        if bash "$setup"; then
            SSH_VERIFIED=1
        else
            warn "deploy key registered but not verified yet (GitHub propagation delay,"
            warn "or this network blocks outbound ssh port 22). Continuing; verify later with:"
            warn "    bash $setup"
        fi
    else
        warn "could not register the deploy key automatically (repo-admin permission required)."
        warn "Send the public key printed above to a repository admin, then re-run:"
        warn "    bash $setup"
    fi
}

finish_auth() {
    if [[ "$SSH_VERIFIED" == 1 ]]; then
        # The box now updates via its own deploy key -- drop the broad
        # personal token that was only needed for this bootstrap. F34: sign
        # out on the REUSE path too (not just when this run logged in) -- a
        # session left behind by an earlier aborted run otherwise lingers on
        # the box forever, and "whose session is it" is unknowable anyway.
        gh auth logout --hostname github.com </dev/null >/dev/null 2>&1 || true
        info "signed your GitHub account out again (the box uses its own deploy key now)"
    elif [[ "$DID_LOGIN" == 1 ]]; then
        warn "keeping your GitHub session so the box stays updatable."
        warn "You can revoke it anytime at github.com/settings/applications."
    else
        warn "a reused GitHub session is still signed in on this box."
        warn "Once the deploy key works, sign it out with: gh auth logout"
    fi
}

AUTH_FINISHED=0

_on_exit() {
    # Single EXIT trap: keep the deploy-key origin (F14) and, on any early
    # death after sign-in, tell the operator about the session left behind
    # (every die() used to exit with the gh token still on the box, silently).
    local rc=$?
    _ensure_ssh_origin
    if [[ "$rc" -ne 0 && "$AUTH_FINISHED" == 0 ]] \
            && gh auth status --hostname github.com >/dev/null 2>&1; then
        warn "this run ended early; your GitHub session is still signed in on this box."
        warn "Remove it with: gh auth logout --hostname github.com"
    fi
    return 0
}

_ensure_ssh_origin() {
    # The wizard's installer may re-clone the repo (operator answers "yes" to
    # "Remove and re-clone?"), which resets origin to HTTPS. Guarantee the box
    # ends with the deploy-key SSH origin no matter how the run exits -- else
    # unattended updates break once the gh session is gone (F14, field-tested).
    local repo="$HOME/projects/RenAndStimPi"
    [[ -f "$HOME/.ssh/rso_deploy_ed25519" && -d "$repo/.git" ]] || return 0
    local want="git@github-rso:$APP_SLUG.git"
    [[ "$(git -C "$repo" remote get-url origin 2>/dev/null)" == "$want" ]] && return 0
    info "restoring the deploy-key SSH origin (a re-clone had reset it)"
    git -C "$repo" remote set-url origin "$want" 2>/dev/null || true
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
    # sign-in and installer prompts work. The subshell probe keeps a failed
    # open (no controlling terminal) from killing the script.
    if [[ ! -t 0 ]] && (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty
    fi

    ensure_prereqs
    github_signin
    trap _on_exit EXIT   # session-left-behind note + SSH origin (F14) on ANY exit
    resolve_release_ref
    ensure_app_clone
    provision_deploy_key
    run_installer "$@"
    finish_auth
    AUTH_FINISHED=1

    echo
    ok "MoreBees $REF installed. Future updates arrive inside the app."
}

# exit on the SAME parsed line as main: with `curl | bash`, bash reads this
# script from stdin, and main() re-points stdin at the terminal for the
# prompts -- if anything had to be read after main returns, bash would sit
# waiting for "script" typed on the keyboard (field-tested hang).
main "$@"; exit $?
