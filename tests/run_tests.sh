#!/usr/bin/env bash
# Bootstrap test suite: no framework, no network, no sudo, no root.
#
# Scenario-catalog style (each test = one failure class). gh, sudo, ps,
# systemctl and id are stubbed on PATH, so the real bootstrap code runs end to
# end inside a sandbox HOME. Most scenarios use real git against a small
# stand-in for the app repository: url.insteadOf maps the app's HTTPS URL and
# its deploy-key URL onto two paths in the sandbox, and each "works" only while
# its path exists (https.git after the stub sign-in, alias.git once the deploy
# key is registered). The absolute paths the bootstrap reads (/usr/local/bin,
# /etc/rso) are redirected through its MB_* test seams.
#
# Run from the repo root:  bash tests/run_tests.sh   (Linux or macOS, bash 3.2+)
#
# Assertions that read files after a run are passed to eval in single quotes,
# so their $variables expand when the assertion runs, not when it is written.
# shellcheck disable=SC2016
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/bootstrap.sh"
PASS=0; FAIL=0
REAL_GIT="$(command -v git || true)"
TEMPLATES="$(mktemp -d)"
CUR_SB=""
trap 'rm -rf "$TEMPLATES"; [ -z "$CUR_SB" ] || rm -rf "$CUR_SB"' EXIT

t_ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
t_fail() {
    FAIL=$((FAIL+1)); echo "  FAIL - $1"
    if [ -n "$CUR_SB" ] && [ -f "$CUR_SB/out.txt" ]; then
        echo "         (exit $(cat "$CUR_SB/rc.txt" 2>/dev/null); output tail:)"
        tail -n 12 "$CUR_SB/out.txt" | sed 's/^/         /'
    fi
}
check() {  # check <description> <command...>
    local d="$1"; shift
    if "$@"; then t_ok "$d"; else t_fail "$d"; fi
}
out_has()   { grep -qF -- "$1" "$CUR_SB/out.txt"; }
out_hasnt() { ! grep -qF -- "$1" "$CUR_SB/out.txt"; }
rc_is()     { [ "$(cat "$CUR_SB/rc.txt")" = "$1" ]; }
event()     { grep -qF -- "$1" "$CUR_SB/events.log"; }
no_event()  { ! grep -qF -- "$1" "$CUR_SB/events.log"; }
call_has()  { grep -qxF -- "$1" "$CUR_SB/installer_call.txt" 2>/dev/null; }
line_of()   { grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1; }
before()    {  # before <first> <second>: both events happened, in this order
    local a b
    a="$(line_of "$CUR_SB/events.log" "$1")"; b="$(line_of "$CUR_SB/events.log" "$2")"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
done_sb() { rm -rf "$CUR_SB"; CUR_SB=""; }

# git as the harness uses it: the sandbox's HOME (its url.insteadOf rules), and
# an author for the stand-in repository's commits.
sgit() {
    HOME="$CUR_SB/home" GIT_CONFIG_NOSYSTEM=1 \
        GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
        GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
        "$REAL_GIT" "$@"
}

# --- Stub and stand-in templates ----------------------------------------------

cat > "$TEMPLATES/gh" <<'EOF'
#!/usr/bin/env bash
# gh stand-in. Its session is the file $STUB_DIR/gh_session.
echo "gh $*" >> "$STUB_DIR/events.log"
case "$1 ${2:-}" in
    "auth status") [ -f "$STUB_DIR/gh_session" ] ;;
    "auth login")
        if [ -c /dev/stdin ] && [ ! -t 0 ]; then echo devnull; else echo other; fi \
            > "$STUB_DIR/gh_login_stdin"
        echo "${GH_PROMPT_DISABLED:-unset}" > "$STUB_DIR/gh_prompt_disabled"
        echo "! First copy your one-time code: TEST-CODE" >&2
        echo "Open this URL to continue in your web browser: https://github.com/login/device" >&2
        [ "${STUB_GH_LOGIN_RC:-0}" = 0 ] || exit "$STUB_GH_LOGIN_RC"
        touch "$STUB_DIR/gh_session"
        # Signed in: the app's https URL now reaches the sandbox remote.
        if [ -d "$STUB_DIR/remote.git" ]; then ln -sfn "$STUB_DIR/remote.git" "$STUB_DIR/https.git"; fi
        exit 0 ;;
    "auth setup-git")
        for h in github.com gist.github.com; do
            git config --global --replace-all "credential.https://$h.helper" ""
            git config --global --add "credential.https://$h.helper" "!/usr/bin/gh auth git-credential"
        done
        exit 0 ;;
    "auth logout") rm -f "$STUB_DIR/gh_session"; exit 0 ;;
    "repo deploy-key")
        # Registered: the deploy-key URL now reaches the sandbox remote.
        [ "${STUB_GH_DEPLOYKEY_RC:-0}" = 0 ] || exit "$STUB_GH_DEPLOYKEY_RC"
        if [ -d "$STUB_DIR/remote.git" ]; then ln -sfn "$STUB_DIR/remote.git" "$STUB_DIR/alias.git"; fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$TEMPLATES/sudo" <<'EOF'
#!/usr/bin/env bash
# sudo stand-in: no root, and an environment as bare as sudo's env_reset: the
# command line's VAR=value assignments plus what the stand-ins need.
assigns=()
while [ $# -gt 0 ]; do
    case "$1" in
        -*) shift ;;
        *=*) assigns+=("$1"); shift ;;
        *) break ;;
    esac
done
echo "sudo $*" >> "$STUB_DIR/events.log"
case "$1" in apt-get|install|tee|chmod) echo "stub sudo refuses: $*" >&2; exit 1 ;; esac
keep=("PATH=$PATH" "HOME=$HOME" "STUB_DIR=$STUB_DIR")
for v in $(env | sed -n 's/^\(STUB_[A-Z0-9_]*\)=.*/\1/p'); do keep+=("$v=${!v}"); done
exec env -i "${keep[@]}" "${assigns[@]}" "$@"
EOF

cat > "$TEMPLATES/ps" <<'EOF'
#!/usr/bin/env bash
if [ -f "$STUB_DIR/ps.txt" ]; then cat "$STUB_DIR/ps.txt"; fi
exit 0
EOF

cat > "$TEMPLATES/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_DIR/events.log"
case "$*" in
    *is-active*rigcam*) [ -f "$STUB_DIR/rigcam_active" ] ;;
    *) exit 0 ;;
esac
EOF

cat > "$TEMPLATES/id" <<'EOF'
#!/usr/bin/env bash
# Never root in a test, whoever runs the suite.
case "${1:-}" in
    -u) echo 1000 ;;
    -un) echo tester ;;
    *) exec /usr/bin/id "$@" ;;
esac
EOF

cat > "$TEMPLATES/gitwrap" <<'EOF'
#!/usr/bin/env bash
exec "$STUB_REAL_GIT" "$@"
EOF

# Fully stubbed git, for the scenarios that end before any clone.
cat > "$TEMPLATES/gitstub" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *"refs/tags/v0.4.7"*) exit 0 ;;              # the v-prefixed tag exists
    *"refs/tags/0.4.7"*)  exit 2 ;;              # the bare pin does not
    *"clone"*) touch "$STUB_DIR/clone_attempted"; exit 1 ;;
    *"ls-remote"*)
        if [ "${STUB_GIT_NO_ACCESS:-0}" = 1 ]; then exit 128; fi
        echo "deadbeef	HEAD"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

# The venv's python, as the recorder's status tool (ctl status --json).
cat > "$TEMPLATES/python" <<'EOF'
#!/usr/bin/env bash
echo "python $*" >> "$STUB_DIR/events.log"
case "${STUB_RIGCAM:-idle}" in
    open) echo '{"camera_running": true, "session_active": true}' ;;
    idle) echo '{"camera_running": true, "session_active": false}' ;;
    hang) exec sleep 30 ;;
    *) echo "could not reach the rigcam service"; exit 1 ;;
esac
EOF

# Stand-in for installers/standalone/install_standalone.sh at a release.
cat > "$TEMPLATES/installer" <<'EOF'
#!/usr/bin/env bash
# stand-in for the MoreBees standalone installer, release @TAG@
if [ "${1:-}" = "--help" ]; then
    echo "Flags:"
    echo "  --only <k[,k...]>    run only these phases"
    if [ "@CAN@" = yes ]; then
        echo "  --reinstall keep|delete   what to do with the data on an installed Pi"
    fi
    exit 0
fi
{
    echo "installer=$0"
    echo "release=@TAG@"
    echo "RSO_GIT_REF=${RSO_GIT_REF-<unset>}"
    echo "RSO_INSTALL_DIR=${RSO_INSTALL_DIR-<unset>}"
    echo "MB_REINSTALL_SOURCE=${MB_REINSTALL_SOURCE-<unset>}"
    for a in "$@"; do echo "arg=$a"; done
} > "$STUB_DIR/installer_call.txt"
echo "installer ran" >> "$STUB_DIR/events.log"
echo "INSTALLER-OUTPUT-MARKER"
if [ "${STUB_MAKE_LAYOUT:-0}" = 1 ]; then
    # What phase 70 leaves behind: ~/rso/current with the checkout's origin.
    rel="$HOME/rso/releases/@TAG@"
    mkdir -p "$rel"
    git -C "$rel" init -q
    git -C "$rel" remote add origin "$(git -C "$RSO_INSTALL_DIR" config --get remote.origin.url)"
    ln -sfn "$rel" "$HOME/rso/current"
fi
exit "${STUB_INSTALLER_RC:-0}"
EOF

cat > "$TEMPLATES/wizard" <<'EOF'
#!/usr/bin/env bash
# stand-in for rso_core/tools/rso_deploy_wizard.sh, release @TAG@
{
    echo "wizard=$0"
    for a in "$@"; do echo "arg=$a"; done
} > "$STUB_DIR/installer_call.txt"
echo "wizard ran" >> "$STUB_DIR/events.log"
exit "${STUB_INSTALLER_RC:-0}"
EOF

# Stand-in for scripts/setup_terminal_deploy_key.sh: it switches the checkout's
# origin to the alias, then verifies through it, which works once alias.git exists.
cat > "$TEMPLATES/deploykey" <<'EOF'
#!/usr/bin/env bash
REPO="$HOME/projects/RenAndStimPi"
while [ $# -gt 0 ]; do
    case "$1" in --repo) REPO="$2"; shift ;; esac
    shift
done
echo "deploy-key setup --repo $REPO" >> "$STUB_DIR/events.log"
mkdir -p "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/rso_deploy_ed25519" ]; then
    : > "$HOME/.ssh/rso_deploy_ed25519"
    echo "ssh-ed25519 AAAA stand-in" > "$HOME/.ssh/rso_deploy_ed25519.pub"
fi
if [ -d "$REPO/.git" ]; then git -C "$REPO" remote set-url origin "git@github-rso:JConeLab/RenAndStimPi.git"; fi
GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "git@github-rso:JConeLab/RenAndStimPi.git" HEAD >/dev/null 2>&1
EOF

# --- Sandboxes ------------------------------------------------------------------

new_sandbox() {  # new_sandbox <real|stub>: a fresh HOME and stub bin; sets CUR_SB
    CUR_SB="$(mktemp -d)"
    mkdir -p "$CUR_SB/home" "$CUR_SB/bin" "$CUR_SB/etc/rso" "$CUR_SB/usr/local/bin"
    : > "$CUR_SB/stdin.txt"
    : > "$CUR_SB/events.log"
    local f
    for f in gh sudo ps systemctl id; do cp "$TEMPLATES/$f" "$CUR_SB/bin/$f"; done
    if [ "$1" = real ]; then
        cp "$TEMPLATES/gitwrap" "$CUR_SB/bin/git"
        cat > "$CUR_SB/home/.gitconfig" <<EOF
[init]
	defaultBranch = main
[advice]
	detachedHead = false
[url "$CUR_SB/https.git"]
	insteadOf = https://github.com/JConeLab/RenAndStimPi.git
[url "$CUR_SB/alias.git"]
	insteadOf = git@github-rso:JConeLab/RenAndStimPi.git
EOF
    else
        cp "$TEMPLATES/gitstub" "$CUR_SB/bin/git"
    fi
    chmod +x "$CUR_SB"/bin/*
}

add_release() {  # add_release <tag> <its installer can reinstall: yes|no>
    local tag="$1" can="$2" src="$CUR_SB/src"
    [ -d "$src/.git" ] || sgit init -q "$src"
    mkdir -p "$src/installers/standalone" "$src/rso_core/tools" "$src/scripts"
    sed -e "s/@TAG@/$tag/g" -e "s/@CAN@/$can/g" "$TEMPLATES/installer" \
        > "$src/installers/standalone/install_standalone.sh"
    sed -e "s/@TAG@/$tag/g" "$TEMPLATES/wizard" > "$src/rso_core/tools/rso_deploy_wizard.sh"
    cp "$TEMPLATES/deploykey" "$src/scripts/setup_terminal_deploy_key.sh"
    echo "$tag" > "$src/VERSION"
    sgit -C "$src" add -A
    sgit -C "$src" commit -q -m "release $tag"
    sgit -C "$src" tag -a -m "$tag" "$tag"
    if [ -d "$CUR_SB/remote.git" ]; then
        sgit -C "$src" push -q "$CUR_SB/remote.git" main "refs/tags/$tag"
    fi
}

fresh_sandbox() {  # a new Pi; the app repository has releases up to v0.4.9
    new_sandbox real
    add_release v0.4.8 no
    add_release v0.4.9 no
    sgit clone -q --bare "$CUR_SB/src" "$CUR_SB/remote.git"
}

installed_sandbox() {  # installed_sandbox <tag> <its installer can reinstall: yes|no>
    # A Pi installed at <tag> by the bootstrap: ~/rso/current and the install
    # folder ~/projects/RenAndStimPi, both fetching through the deploy key,
    # which works; the wrappers and the role file of phases 50, 55 and 70.
    local h
    new_sandbox real
    add_release v0.4.8 no
    add_release "$1" "$2"
    sgit clone -q --bare "$CUR_SB/src" "$CUR_SB/remote.git"
    ln -s "$CUR_SB/remote.git" "$CUR_SB/alias.git"
    h="$CUR_SB/home"
    mkdir -p "$h/rso/releases" "$h/rso/shared/data" "$h/projects"
    sgit clone -q "git@github-rso:JConeLab/RenAndStimPi.git" "$h/rso/releases/$1"
    sgit -C "$h/rso/releases/$1" checkout -q --detach "$1"
    ln -s "$h/rso/releases/$1" "$h/rso/current"
    sgit clone -q "git@github-rso:JConeLab/RenAndStimPi.git" "$h/projects/RenAndStimPi"
    sgit -C "$h/projects/RenAndStimPi" checkout -q --detach "$1"
    {
        echo '#!/bin/bash'
        echo '# MoreBees GUI (written by installers/standalone/modules/55-cli.sh).'
        echo 'if [ -x /usr/local/bin/rso-standalone-gui ]; then'
        echo '    exec /usr/local/bin/rso-standalone-gui "$@"'
        echo 'fi'
        echo "source \"$h/projects/RenAndStimPi/venv/bin/activate\""
        echo "cd \"$h/projects/RenAndStimPi\" || exit 1"
        echo "export PYTHONPATH=\"$h/projects/RenAndStimPi\""
        echo 'exec python -m renandstimpi.gui_launcher.app "$@"'
    } > "$CUR_SB/usr/local/bin/renandstimpi-gui"
    printf '#!/bin/bash\nexec "$HOME/rso/current/scripts/runtime/launch.sh" "$@"\n' \
        > "$CUR_SB/usr/local/bin/rso-standalone-gui"
    echo standalone > "$CUR_SB/etc/rso/role"
    mkdir -p "$h/rso/shared/venv/bin"
    cp "$TEMPLATES/python" "$h/rso/shared/venv/bin/python"
    chmod +x "$h/rso/shared/venv/bin/python"
}

run_bootstrap() {  # run_bootstrap [VAR=value ...] -- [bootstrap arguments ...]
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    if [ "${1:-}" = "--" ]; then shift; fi
    ( cd "$CUR_SB/home" && env -i HOME="$CUR_SB/home" PATH="$CUR_SB/bin:/usr/bin:/bin" \
          STUB_DIR="$CUR_SB" STUB_REAL_GIT="$REAL_GIT" TERM=dumb GIT_CONFIG_NOSYSTEM=1 \
          GIT_SSH_COMMAND=false MB_BIN_DIR="$CUR_SB/usr/local/bin" \
          MB_ROLE_FILE="$CUR_SB/etc/rso/role" MB_RIGCAM_ENV="$CUR_SB/etc/rso/rigcam.env" \
          ${envs[@]+"${envs[@]}"} "$BASH" "$SCRIPT" "$@" \
          <"$CUR_SB/stdin.txt" >"$CUR_SB/out.txt" 2>&1 )
    echo $? > "$CUR_SB/rc.txt"
}

snapshot() {  # snapshot <checkout>: HEAD, origin and working-tree state
    sgit -C "$1" rev-parse HEAD
    sgit -C "$1" config --get remote.origin.url
    sgit -C "$1" status --porcelain
}
no_build_left() {
    local d
    for d in "$CUR_SB"/home/.cache/morebees/build.*; do
        if [ -e "$d" ]; then return 1; fi
    done
    return 0
}
gh_helpers_gone() {
    ! sgit config --global --get-all credential.https://github.com.helper >/dev/null 2>&1 \
        && ! sgit config --global --get-all credential.https://gist.github.com.helper >/dev/null 2>&1
}
the_log() {
    local f
    for f in "$CUR_SB"/home/.local/state/morebees/bootstrap-*.log; do
        if [ -f "$f" ]; then echo "$f"; return 0; fi
    done
    return 1
}
mode_600() { [ -n "$1" ] && [ -n "$(find "$1" -prune -perm 600)" ]; }

if [ -z "$REAL_GIT" ]; then echo "git is required to run the tests"; exit 1; fi

# --- 1 to 3: the script as a file -----------------------------------------------

echo "1. syntax"
if bash -n "$SCRIPT"; then t_ok "bash -n clean"; else t_fail "bash -n"; fi

echo "2. curl|bash truncation armor (no top-level side effects)"
if [ "$(tail -1 "$SCRIPT")" = 'main "$@"; exit $?' ]; then
    t_ok "last line is the single entry point"
else
    t_fail "last line must be: main \"\$@\"; exit \$?"
fi
for n in 500 2000 8000; do
    sb="$(mktemp -d)"; mkdir -p "$sb/home"
    ( cd "$sb/home" && head -c "$n" "$SCRIPT" | env -i HOME="$sb/home" PATH=/usr/bin:/bin bash >/dev/null 2>&1 )
    if [ ! -e "$sb/home/projects" ] && [ ! -e "$sb/home/.local" ]; then
        t_ok "truncated at $n bytes: no side effects"
    else
        t_fail "truncated at $n bytes CREATED files in HOME"
    fi
    rm -rf "$sb"
done

echo "3. typo'd release pin dies early with the did-you-mean hint"
new_sandbox stub
touch "$CUR_SB/gh_session"
run_bootstrap RSO_GIT_REF=0.4.7 -- --standalone
check "nonzero exit" eval '! rc_is 0'
check "did-you-mean hint printed" out_has "did you mean v0.4.7"
check "died BEFORE any clone attempt" test ! -e "$CUR_SB/clone_attempted"
check "failure report names the failing step" eval 'out_has "step:  resolve-release" && out_has "failure report"'
done_sb

# --- 4 to 6: sign-in ------------------------------------------------------------

echo "4. the sign-in asks gh nothing interactive (no git question, no workflow scope)"
new_sandbox stub
run_bootstrap RSO_GIT_REF=0.4.7 -- --standalone
check "gh auth login reads stdin from /dev/null" test "$(cat "$CUR_SB/gh_login_stdin" 2>/dev/null)" = devnull
check "gh auth login runs with GH_PROMPT_DISABLED=1" test "$(cat "$CUR_SB/gh_prompt_disabled" 2>/dev/null)" = 1
check "operator told to open the URL on any device" out_has "Open the URL on any device"
done_sb

echo "5. the EXIT trap is armed before the sign-in"
new_sandbox stub
touch "$CUR_SB/gh_session"
run_bootstrap STUB_GIT_NO_ACCESS=1 -- --standalone
check "an account without access stops the run" eval 'out_has "cannot access" && rc_is 1'
check "the session left behind is reported" out_has "your GitHub session is still signed in"
check "the log path is printed" out_has "Bootstrap log:"
done_sb

echo "6. a failed sign-in is logged"
new_sandbox stub
run_bootstrap STUB_GH_LOGIN_RC=1 -- --standalone
check "exit 1 with a failure report" eval 'rc_is 1 && out_has "bootstrap failure report"'
check "the report names the bootstrap log" out_has "bootstrap log: $CUR_SB/home/.local/state/morebees/bootstrap-"
done_sb

# --- 7 to 10: a new Pi ----------------------------------------------------------

echo "7. standalone: the token leaves as soon as the deploy key verifies"
fresh_sandbox
run_bootstrap STUB_MAKE_LAYOUT=1 -- --standalone
check "exit 0" rc_is 0
check "signed out BEFORE the installer ran" before "gh auth logout" "installer ran"
check "deploy key registered and verified first" before "gh repo deploy-key" "gh auth logout"
check "gh's credential-helper lines removed from ~/.gitconfig" gh_helpers_gone
check "sign-out says the token stays valid until revoked" \
    out_has "stays valid on GitHub until you revoke it: https://github.com/settings/applications"
check "installer got the release and the checkout" \
    eval 'call_has "RSO_GIT_REF=v0.4.9" && call_has "RSO_INSTALL_DIR=$CUR_SB/home/projects/RenAndStimPi"'
check "no --standalone forwarded" eval '! grep -q "^arg=--standalone$" "$CUR_SB/installer_call.txt"'
check "closing lines: installed, updates in the app" \
    eval 'out_has "MoreBees v0.4.9 is installed." && out_has "Future updates arrive inside the app."'
done_sb

echo "8. terminal: the session stays until the wizard has finished"
fresh_sandbox
run_bootstrap -- --terminal
check "exit 0" rc_is 0
check "signed out AFTER the wizard ran" before "wizard ran" "gh auth logout"
check "gh's credential-helper lines removed" gh_helpers_gone
done_sb

echo "9. the closing line tells the truth"
fresh_sandbox
run_bootstrap -- --standalone
check "exit 0" rc_is 0
check "no update promise without ~/rso/current" out_hasnt "Future updates arrive inside the app."
check "says why" out_has "There is no release folder at ~/rso/current"
done_sb
fresh_sandbox
run_bootstrap STUB_MAKE_LAYOUT=1 STUB_GH_DEPLOYKEY_RC=1 -- --standalone
check "key not verified: session kept, no update promise" \
    eval 'out_has "keeping your GitHub session" && out_hasnt "Future updates arrive inside the app."'
check "key not verified: no sign-out before the installer" no_event "gh auth logout"
done_sb

echo "10. the installer's exit status, said plainly and passed on"
for pair in "0|MoreBees v0.4.9 is installed." \
            "2|MoreBees v0.4.9 is installed with problems; see /var/log/renandstimpi_standalone_installer.log." \
            "3|Stopped before installing: see the installer's message above." \
            "4|The reinstall did not finish; the previous installation was put back." \
            "130|Interrupted. Run the same command again: it finishes or undoes what was started." \
            "5|the standalone installer stopped with status 5"; do
    code="${pair%%|*}"; text="${pair#*|}"
    fresh_sandbox
    run_bootstrap STUB_INSTALLER_RC="$code" -- --standalone
    check "installer exit $code: bootstrap exits $code" rc_is "$code"
    check "installer exit $code: says \"$text\"" out_has "$text"
    if [ "$code" = 5 ]; then
        check "installer exit 5: failure report" out_has "bootstrap failure report"
    else
        check "installer exit $code: no failure report" out_hasnt "bootstrap failure report"
    fi
    done_sb
done

echo "11. the bootstrap's own log"
fresh_sandbox
run_bootstrap -- --standalone
log="$(the_log)"
check "log under ~/.local/state/morebees" test -n "$log"
check "log is mode 0600" mode_600 "$log"
check "log path printed at the end" eval 'tail -n 1 "$CUR_SB/out.txt" | grep -qF "Bootstrap log: $log"'
check "log has the installer's command and status" \
    eval 'grep -q "running: sudo RSO_GIT_REF=v0.4.9" "$log" && grep -q "installer exit status: 0" "$log"'
check "log is not a copy of the installer's output" eval '! grep -q INSTALLER-OUTPUT-MARKER "$log"'
done_sb
fresh_sandbox
run_bootstrap XDG_STATE_HOME="$CUR_SB/state" -- --standalone
check "XDG_STATE_HOME is honoured" eval 'ls "$CUR_SB"/state/morebees/bootstrap-*.log >/dev/null 2>&1'
done_sb

# --- 12 to 19: a Pi that already has MoreBees -------------------------------------

echo "12. --only on an installed Pi: the installed release's installer, no sign-in"
installed_sandbox v0.4.9 no
before_projects="$(snapshot "$CUR_SB/home/projects/RenAndStimPi")"
run_bootstrap -- --standalone --only 75
check "exit 0" rc_is 0
check "ran ~/rso/current's installer" call_has "installer=$CUR_SB/home/rso/current/installers/standalone/install_standalone.sh"
check "with the installed tag" call_has "RSO_GIT_REF=v0.4.9"
check "with the install folder from the renandstimpi-gui wrapper" \
    call_has "RSO_INSTALL_DIR=$CUR_SB/home/projects/RenAndStimPi"
check "arguments forwarded without --standalone" \
    eval 'call_has "arg=--only" && call_has "arg=75" && ! call_has "arg=--standalone"'
check "no GitHub sign-in" no_event "gh auth login"
check "the checkout in ~/projects is untouched" test "$(snapshot "$CUR_SB/home/projects/RenAndStimPi")" = "$before_projects"
done_sb
installed_sandbox v0.4.9 no
rm -rf "$CUR_SB/home/projects"
run_bootstrap -- --standalone --only camera
check "no clone into ~/projects" test ! -e "$CUR_SB/home/projects"
check "the installer still ran" event "installer ran"
done_sb
installed_sandbox v0.4.9 no
rm "$CUR_SB/home/rso/current"
run_bootstrap -- --standalone --only 40
check "no ~/rso/current: the install folder's installer runs" \
    call_has "installer=$CUR_SB/home/projects/RenAndStimPi/installers/standalone/install_standalone.sh"
check "... with RSO_INSTALL_DIR set to it" call_has "RSO_INSTALL_DIR=$CUR_SB/home/projects/RenAndStimPi"
done_sb

echo "13. --only refuses while MoreBees is in use (phases 20, 70, 75, 90)"
installed_sandbox v0.4.9 no
echo "4321 $CUR_SB/home/rso/shared/venv/bin/python -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 75
check "a running window: exit 3" rc_is 3
check "says what is running" eval 'out_has "MoreBees is in use" && out_has "pid 4321"'
check "the installer did not run" no_event "installer ran"
done_sb
installed_sandbox v0.4.9 no
echo "4321 python3 -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 40
check "a phase that does not touch running code is not held back" event "installer ran"
done_sb
installed_sandbox v0.4.9 no
echo "77 /usr/bin/python3 -m renandstimpi.modules.camera.service --width 1280" > "$CUR_SB/ps.txt"
touch "$CUR_SB/rigcam_active"
run_bootstrap STUB_RIGCAM=idle -- --standalone --only camera
check "an idle recorder is not in use" event "installer ran"
done_sb
installed_sandbox v0.4.9 no
touch "$CUR_SB/rigcam_active"
run_bootstrap STUB_RIGCAM=open -- --standalone --only camera
check "a recorder with a session open: exit 3" eval 'rc_is 3 && out_has "has a session open"'
done_sb
installed_sandbox v0.4.9 no
touch "$CUR_SB/rigcam_active"
run_bootstrap STUB_RIGCAM=hang MB_RIGCAM_TIMEOUT=1 -- --standalone --only 90
check "a recorder that does not answer: exit 3" eval 'rc_is 3 && out_has "did not answer its status request within 1 s"'
done_sb

echo "14. a full run whose target installer cannot reinstall: guidance, nothing changed"
installed_sandbox v0.4.9 no
add_release v0.5.0-rc.2 no
before_projects="$(snapshot "$CUR_SB/home/projects/RenAndStimPi")"
before_current="$(snapshot "$CUR_SB/home/rso/current")"
run_bootstrap RSO_GIT_REF=v0.5.0-rc.2 -- --standalone
check "exit 3" rc_is 3
check "the guidance card" \
    eval 'out_has "MoreBees v0.4.9 is installed on this Pi." && out_has "never remove ~/rso" && out_has "Nothing was changed."'
check "lists the newest release tags" out_has "Newest release tags: v0.5.0-rc.2 v0.4.9 v0.4.8"
check "the temporary copy is removed" no_build_left
check "the checkout in ~/projects keeps its HEAD and origin" test "$(snapshot "$CUR_SB/home/projects/RenAndStimPi")" = "$before_projects"
check "the release in ~/rso/current is unchanged" test "$(snapshot "$CUR_SB/home/rso/current")" = "$before_current"
check "no installer ran and no sign-in" eval 'no_event "installer ran" && no_event "gh auth login"'
done_sb
installed_sandbox v0.4.9 no
run_bootstrap -- --standalone
check "no newer release: the same card, exit 3" eval 'rc_is 3 && out_has "Reinstalling it needs a release"'
done_sb

echo "15. a full run whose target installer can reinstall: the hand-off"
installed_sandbox v0.4.9 no
add_release v0.5.0-rc.3 yes
add_release v0.5.0 yes
before_projects="$(snapshot "$CUR_SB/home/projects/RenAndStimPi")"
run_bootstrap -- --standalone --reinstall keep --non-interactive --verbose
check "exit 0" rc_is 0
check "the newest stable release newer than the installed one" call_has "RSO_GIT_REF=v0.5.0"
check "MB_REINSTALL_SOURCE=bootstrap" call_has "MB_REINSTALL_SOURCE=bootstrap"
check "no RSO_INSTALL_DIR" call_has "RSO_INSTALL_DIR=<unset>"
check "the installer runs from the temporary copy" \
    eval 'grep -q "^installer=$CUR_SB/home/.cache/morebees/build\." "$CUR_SB/installer_call.txt"'
check "the operator's arguments, verbatim, without --standalone" \
    test "$(grep '^arg=' "$CUR_SB/installer_call.txt" | tr '\n' ' ')" = "arg=--reinstall arg=keep arg=--non-interactive arg=--verbose "
check "the temporary copy is removed afterwards" no_build_left
check "the checkout in ~/projects is untouched" test "$(snapshot "$CUR_SB/home/projects/RenAndStimPi")" = "$before_projects"
check "no GitHub sign-in (the deploy key fetched the release)" no_event "gh auth login"
done_sb
installed_sandbox v0.5.0-rc.3 yes
run_bootstrap -- --standalone
check "the installed release's installer can reinstall: it is the target" call_has "RSO_GIT_REF=v0.5.0-rc.3"
done_sb

echo "16. a full run when the Pi's deploy key no longer reaches GitHub"
installed_sandbox v0.4.9 no
add_release v0.5.0 yes
rm "$CUR_SB/alias.git"
run_bootstrap RSO_GIT_REF=v0.5.0 -- --standalone
check "exit 0" rc_is 0
check "signed in with the device code" event "gh auth login"
check "the deploy key provisioned against the temporary copy only" \
    eval 'grep -q "deploy-key setup --repo $CUR_SB/home/.cache/morebees/build\." "$CUR_SB/events.log"'
check "signed out before the installer ran" before "gh auth logout" "installer ran"
check "the target installer ran" call_has "RSO_GIT_REF=v0.5.0"
done_sb

echo "17. a full run refuses targets that are not newer release tags"
installed_sandbox v0.5.0 yes
run_bootstrap RSO_GIT_REF=v0.4.8 -- --standalone
check "an older tag: exit 3" eval 'rc_is 3 && out_has "older than the installed v0.5.0"'
check "an older tag: nothing ran" no_event "installer ran"
done_sb
installed_sandbox v0.5.0 yes
run_bootstrap RSO_GIT_REF=v0.4.8 -- --standalone --allow-older-release
check "--allow-older-release lets it through to v0.4.8's installer" \
    eval 'out_hasnt "older than the installed" && out_has "Reinstalling it needs a release"'
done_sb
installed_sandbox v0.5.0 yes
run_bootstrap RSO_GIT_REF=main -- --standalone
check "a branch: exit 3" eval 'rc_is 3 && out_has "release tags only"'
done_sb
installed_sandbox v0.5.0 yes
run_bootstrap RSO_GIT_REF=0123abcd -- --standalone
check "a commit: exit 3" eval 'rc_is 3 && out_has "release tags only"'
done_sb

echo "18. another role on this computer"
installed_sandbox v0.4.9 no
echo terminal > "$CUR_SB/etc/rso/role"
run_bootstrap -- --standalone
check "exit 3" rc_is 3
check "says what it is" out_has "This computer is set up as a MoreBees terminal ($CUR_SB/etc/rso/role)."
check "and that nothing changed" out_has "The standalone installer does not reinstall it. Nothing was changed."
check "no sign-in, no installer" eval 'no_event "gh auth" && no_event "installer ran"'
done_sb

echo "19. SemVer precedence"
if (
    # The bootstrap runs main() on its last line, so load just the comparison.
    eval "$(sed -n '/^semver_cmp() {/,/^}/p' "$SCRIPT")"
    lt() { semver_cmp "$1" "$2" && [ "$SEMVER_CMP" = -1 ] && semver_cmp "$2" "$1" && [ "$SEMVER_CMP" = 1 ]; }
    ok=1
    for pair in "v0.4.9 v0.5.0-rc.1" "v0.5.0-rc.1 v0.5.0-rc.2" "v0.5.0-rc.2 v0.5.0-rc.10" \
                "v0.5.0-rc.10 v0.5.0" "v0.4.10 v0.5.0" "v0.4.9 v0.4.10" "v1.0.0-alpha v1.0.0-alpha.1" \
                "v1.0.0-alpha.1 v1.0.0-alpha.beta" "v1.0.0-beta.11 v1.0.0-rc.1"; do
        # shellcheck disable=SC2086  # two words on purpose
        lt $pair || { echo "    not ordered: $pair"; ok=0; }
    done
    semver_cmp v0.5.0 v0.5.0 && [ "$SEMVER_CMP" = 0 ] || { echo "    v0.5.0 != v0.5.0"; ok=0; }
    if semver_cmp test-pr12 v0.5.0; then echo "    test-pr12 was compared"; ok=0; fi
    [ "$ok" = 1 ]
); then
    t_ok "v0.4.9 < v0.5.0-rc.1 < v0.5.0-rc.2 < v0.5.0-rc.10 < v0.5.0, and the SemVer 2.0 examples"
else
    t_fail "SemVer precedence"
fi

echo "20. the README's pin"
pin_rc=0; bash "$HERE/scripts/pin.sh" --check >/dev/null 2>&1 || pin_rc=$?
if [ "$pin_rc" = 0 ]; then
    t_ok "README's SHA-256 matches bootstrap.sh at the pinned commit"
elif [ "$pin_rc" = 2 ]; then
    echo "  skip - the pinned commit is not in this clone (shallow?)"
else
    t_fail "scripts/pin.sh --check failed (exit $pin_rc)"
fi
pin_dir="$(mktemp -d)"
cp "$HERE/README.md" "$pin_dir/README.md"
head_commit="$("$REAL_GIT" -C "$HERE" rev-parse HEAD)"
head_sum="$("$REAL_GIT" -C "$HERE" show "HEAD:bootstrap.sh" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)"
urls_before="$(grep -c 'morebees-installer/[0-9a-f]\{40\}/bootstrap.sh' "$pin_dir/README.md")"
if PIN_README="$pin_dir/README.md" bash "$HERE/scripts/pin.sh" HEAD >/dev/null 2>&1 \
        && [ "$(grep -c "morebees-installer/$head_commit/bootstrap.sh" "$pin_dir/README.md")" = "$urls_before" ] \
        && grep -q "$head_sum" "$pin_dir/README.md" \
        && PIN_README="$pin_dir/README.md" bash "$HERE/scripts/pin.sh" --check >/dev/null 2>&1; then
    t_ok "scripts/pin.sh rewrites every pinned URL and the checksum"
else
    t_fail "scripts/pin.sh <commit>"
fi
rm -rf "$pin_dir"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
