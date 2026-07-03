#!/usr/bin/env bash
#
# MoreBees — one-line bootstrap installer
#
#   curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/bootstrap.sh | bash
#
# Installs the MoreBees experiment orchestrator (RenAndStimPi) on a fresh
# Ubuntu Terminal PC or Raspberry Pi. The application repository is PRIVATE,
# so this script first signs you in to GitHub with your own account (a
# one-time browser device code — no tokens to paste), then clones the latest
# release and hands off to the platform installer, which prompts for the few
# things it needs (install mode, rig ID, ...).
#
# After a Terminal PC install it also provisions a read-only DEPLOY KEY so
# the box can receive updates unattended, then signs your account back out.
#
# Environment overrides:
#   RSO_APP_REPO   app repo slug           (default: JConeLab/RenAndStimPi)
#   RSO_GIT_REF    tag/branch/SHA to install (default: latest stable vX.Y.Z)
#   GH_TOKEN       pre-issued token for fully headless installs (skips the
#                  browser step; needs read access to the app repo)
#
# All extra args are forwarded to the platform installer, e.g.:
#   ... | bash -s -- --terminal --dev-mode
#
# This file contains no secrets. Everything below runs inside main(), called
# on the last line, so a truncated download can never execute half a script.
set -Eeuo pipefail

APP_SLUG="${RSO_APP_REPO:-JConeLab/RenAndStimPi}"
DID_LOGIN=0
SSH_VERIFIED=0
STAGE_DIR=""

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${BLUE}[bootstrap]${NC} $*"; }
ok()   { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*" >&2; }
die()  { echo -e "${RED}[bootstrap]${NC} $*" >&2; exit 1; }

cleanup() {
    [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]] && rm -rf "$STAGE_DIR"
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
        gh auth login --hostname github.com --git-protocol https --web \
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
    if [[ -z "$REF" ]]; then
        REF=$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags "https://github.com/$APP_SLUG.git" 'v*' \
            | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    fi
    [[ -n "$REF" ]] || die "no stable release tag (vX.Y.Z) found on $APP_SLUG"
    info "installing release: $REF"
}

run_platform_installer() {
    # Shallow staging clone -- only to obtain the installer. The installer
    # itself makes (and owns) the real clone at its canonical location.
    STAGE_DIR=$(mktemp -d /tmp/morebees-bootstrap.XXXXXX)
    info "fetching the installer ($REF)…"
    # Sparse + blobless: the staging clone only needs the installer scripts,
    # not the ~1 GB of app/ML data -- the installer itself makes the real full
    # clone (with progress). Falls back to a full shallow clone on old git.
    if GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$REF" \
            --filter=blob:none --sparse \
            "https://github.com/$APP_SLUG.git" "$STAGE_DIR/app" 2>/dev/null; then
        GIT_TERMINAL_PROMPT=0 git -C "$STAGE_DIR/app" sparse-checkout set \
            rso_terminal_installer scripts installers renandstimpi/rso_comm/installer
    else
        warn "sparse clone unavailable -- falling back to a full download (~1 GB, progress below)"
        rm -rf "$STAGE_DIR/app"
        GIT_TERMINAL_PROMPT=0 git clone --progress --depth 1 --branch "$REF" \
            "https://github.com/$APP_SLUG.git" "$STAGE_DIR/app"
    fi

    [[ -f "$STAGE_DIR/app/install.sh" ]] || die "install.sh missing from $REF"
    echo
    info "handing off to the MoreBees platform installer…"
    echo
    # Run as a child (NOT exec): we still provision the deploy key afterwards.
    RSO_GIT_REF="$REF" bash "$STAGE_DIR/app/install.sh" "$@" \
        || die "the platform installer reported an error -- see its log output above."
}

provision_deploy_key() {
    # Terminal PC only: give the box its own least-privilege, read-only SSH
    # deploy key so updates never depend on a person's account. Requires the
    # signed-in account to be a repo ADMIN to auto-register; otherwise the
    # public key is printed for an admin to add.
    local repo_dir="$HOME/projects/RenAndStimPi"
    local setup="$repo_dir/scripts/setup_terminal_deploy_key.sh"
    local pub="$HOME/.ssh/rso_deploy_ed25519.pub"

    [[ -d "$repo_dir/.git" ]] || return 0   # not a Terminal PC install
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
        bash "$setup" && SSH_VERIFIED=1
    else
        warn "could not register the deploy key automatically (repo-admin permission required)."
        warn "Send the public key printed above to a repository admin, then re-run:"
        warn "    bash $setup"
    fi
}

finish_auth() {
    if [[ "$DID_LOGIN" == 1 && "$SSH_VERIFIED" == 1 ]]; then
        # The box now updates via its own deploy key -- drop the broad
        # personal token that was only needed for this bootstrap.
        gh auth logout --hostname github.com </dev/null >/dev/null 2>&1 || true
        info "signed your GitHub account out again (the box uses its own deploy key now)"
    elif [[ "$DID_LOGIN" == 1 ]]; then
        warn "keeping your GitHub session so the box stays updatable."
        warn "You can revoke it anytime at github.com/settings/applications."
    fi
}

main() {
    echo
    echo "========================================"
    echo " MoreBees installer — many rigs, one hive"
    echo "========================================"
    echo

    [[ $(id -u) -ne 0 ]] || die "run as your normal user, not root -- it will sudo when needed."

    # Piped from curl, stdin is the pipe; reattach the real terminal so the
    # sign-in and installer prompts work. The subshell probe keeps a failed
    # open (no controlling terminal) from killing the script.
    if [[ ! -t 0 ]] && (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty
    fi

    trap cleanup EXIT

    ensure_prereqs
    github_signin
    resolve_release_ref
    run_platform_installer "$@"
    provision_deploy_key
    finish_auth

    echo
    ok "MoreBees $REF installed. Future updates arrive inside the app."
}

# exit on the SAME parsed line as main: with `curl | bash`, bash reads this
# script from stdin, and main() re-points stdin at the terminal for the
# prompts -- if anything had to be read after main returns, bash would sit
# waiting for "script" typed on the keyboard (field-tested hang).
main "$@"; exit $?
