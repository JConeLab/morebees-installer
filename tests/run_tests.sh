#!/usr/bin/env bash
# Bootstrap test suite: no framework, no network, no sudo, no root.
#
# Scenario-catalog style (each test = one failure class). gh, sudo, ps,
# systemctl and id, and findmnt, journalctl, dmesg and sync for the NVMe check,
# are stubbed on PATH, so the real bootstrap code runs end to end inside a
# sandbox HOME. Most scenarios use real git against a small stand-in for the app
# repository: url.insteadOf maps the app's HTTPS URL and its deploy-key URL onto
# two paths in the sandbox, and each "works" only while its path exists
# (https.git after the stub sign-in, alias.git once the deploy key is
# registered). The absolute paths the bootstrap reads (/usr/local/bin, /etc/rso,
# /proc, /sys, /boot/firmware, /dev/tty) are redirected through its MB_* test
# seams, so no test reads or changes the computer it runs on.
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
done_sb() { chmod -R u+w "$CUR_SB" 2>/dev/null; rm -rf "$CUR_SB"; CUR_SB=""; }

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
last="${!#}"
if [ "${STUB_SUDO_REFUSE_ALL:-0}" = 1 ]; then
    # Three wrong passwords, a user sudo does not allow, or no terminal to ask on.
    echo "stub sudo: a password is required" >&2; exit 1
fi
if [ "${STUB_CP_PARTIAL:-0}" = 1 ] && [ "$1" = cp ]; then
    # A full boot partition: the copy of the line starts, then fails part way.
    case "$last" in *.before-morebees-nvme*) head -c 10 "$3" > "$last"; echo "stub sudo: cp: no space left" >&2; exit 1 ;; esac
fi
if [ -n "${STUB_SUDO_FAIL:-}" ] && [ "$1" = "$STUB_SUDO_FAIL" ]; then
    echo "stub sudo: $1 failed" >&2; exit 1
fi
if [ -n "${STUB_SUDO_INTERRUPT:-}" ] && [ "$1" = "$STUB_SUDO_INTERRUPT" ]; then
    # A Ctrl+C while this command runs: the bootstrap gets SIGINT, the command never ran.
    kill -INT "$PPID"; exit 1
fi
if [ -n "${STUB_EDIT_BOOT_ON:-}" ] && [ "$1" = "$STUB_EDIT_BOOT_ON" ]; then
    # Someone else edits the boot line while the bootstrap works on it.
    printf ' edited' >> "$STUB_DIR/boot/firmware/cmdline.txt"
fi
case "$1" in apt-get|install|tee|chmod) echo "stub sudo refuses: $*" >&2; exit 1 ;; esac
if [ "$1" = rm ]; then
    # Root could remove what the operator cannot: give the operator the rights.
    for a in "$@"; do
        case "$a" in /*) [ ! -e "$a" ] || chmod -R u+w "$a" 2>/dev/null ;; esac
    done
fi
keep=("PATH=$PATH" "HOME=$HOME" "STUB_DIR=$STUB_DIR")
for v in $(env | sed -n 's/^\(STUB_[A-Z0-9_]*\)=.*/\1/p'); do keep+=("$v=${!v}"); done
# STUB_CORRUPT: a file that does not read back as written. staged: the new
# line's copy in the boot folder; backup: the copy of the old line; moved: the
# boot line after the move; restore: that, and the copy back fails too;
# putback: that, and the copy back succeeds but does not read back either.
post=""
case "${STUB_CORRUPT:-}:$1" in
    staged:cp) case "$last" in *cmdline.txt.morebees-new.*) post=corrupt ;; esac ;;
    backup:cp) case "$last" in *.before-morebees-nvme*) post=corrupt ;; esac ;;
    moved:mv|restore:mv|putback:mv) post=corrupt ;;
    restore:cp) case "$last" in */cmdline.txt) echo "stub sudo: cp failed" >&2; exit 1 ;; esac ;;
    putback:cp) case "$last" in */cmdline.txt) post=corrupt ;; esac ;;
esac
# STUB_SUDO_INTERRUPT_AFTER: the command runs, then a Ctrl+C reaches the bootstrap.
if [ -n "${STUB_SUDO_INTERRUPT_AFTER:-}" ] && [ "$1" = "$STUB_SUDO_INTERRUPT_AFTER" ]; then
    post="$post interrupt"
fi
# STUB_SUDO_FAIL_AFTER: the command runs, and sudo still reports a failure.
if [ -n "${STUB_SUDO_FAIL_AFTER:-}" ] && [ "$1" = "$STUB_SUDO_FAIL_AFTER" ]; then
    post="$post fail"
fi
# STUB_SUDO_KILL_AFTER: the command runs, then the bootstrap dies at once, as
# when the power is cut: no trap runs.
if [ -n "${STUB_SUDO_KILL_AFTER:-}" ] && [ "$1" = "$STUB_SUDO_KILL_AFTER" ]; then
    post="$post kill"
fi
if [ -z "$post" ]; then exec env -i "${keep[@]}" "${assigns[@]}" "$@"; fi
rc=0
env -i "${keep[@]}" "${assigns[@]}" "$@" || rc=$?
case " $post " in *" corrupt "*) printf 'x' >> "$last" ;; esac
case " $post " in *" interrupt "*) kill -INT "$PPID" ;; esac
case " $post " in *" kill "*) kill -KILL "$PPID" ;; esac
case " $post " in *" fail "*) rc=1 ;; esac
exit "$rc"
EOF

# sha256sum stand-in with GNU's -c --quiet, which macOS's lacks: a file's sum,
# or -c with "<sum>  <file>" lines on standard input, as the undo command runs.
cat > "$TEMPLATES/sha256sum" <<'EOF'
#!/usr/bin/env bash
hash_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else /usr/bin/sha256sum "$1"; fi | cut -d' ' -f1
}
if [ "${1:-}" = -c ]; then
    rc=0
    while read -r sum file; do
        [ -n "$sum" ] || continue
        if [ "$(hash_of "$file" 2>/dev/null)" != "$sum" ]; then echo "$file: FAILED" >&2; rc=1; fi
    done
    exit "$rc"
fi
for f in "$@"; do printf '%s  %s\n' "$(hash_of "$f")" "$f"; done
EOF

# lsblk stand-in: the device stack under the root, from $STUB_DIR/lsblk.txt.
cat > "$TEMPLATES/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "lsblk $*" >> "$STUB_DIR/events.log"
[ -f "$STUB_DIR/lsblk.txt" ] || exit 1
cat "$STUB_DIR/lsblk.txt"
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

# The NVMe check's system reads: the root filesystem's device, this boot's
# kernel log (the journal, then the kernel's buffer), and sync.
cat > "$TEMPLATES/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "findmnt $*" >> "$STUB_DIR/events.log"
[ -f "$STUB_DIR/root_source" ] || exit 1
cat "$STUB_DIR/root_source"
EOF

cat > "$TEMPLATES/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "journalctl $*" >> "$STUB_DIR/events.log"
if [ -f "$STUB_DIR/journal.log" ]; then cat "$STUB_DIR/journal.log"; fi
exit 0
EOF

cat > "$TEMPLATES/dmesg" <<'EOF'
#!/usr/bin/env bash
echo "dmesg $*" >> "$STUB_DIR/events.log"
[ -f "$STUB_DIR/dmesg.log" ] || exit 1
cat "$STUB_DIR/dmesg.log"
EOF

cat > "$TEMPLATES/sync" <<'EOF'
#!/usr/bin/env bash
echo "sync $*" >> "$STUB_DIR/events.log"
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
    if [ -n "@HELP@" ]; then cat "@HELP@"; exit 0; fi
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
    echo "PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE-<unset>}"
    for a in "$@"; do echo "arg=$a"; done
} > "$STUB_DIR/installer_call.txt"
echo "installer ran" >> "$STUB_DIR/events.log"
echo "INSTALLER-OUTPUT-MARKER"
if [ "${STUB_ROOT_FILES:-0}" = 1 ]; then
    # What root leaves in the tree it ran from: a folder the operator cannot empty.
    tree="$(cd "$(dirname "$0")/../.." && pwd)"
    mkdir -p "$tree/__pycache__" && : > "$tree/__pycache__/m.pyc" && chmod 555 "$tree/__pycache__"
fi
if [ "${STUB_CUT_OUTPUT:-0}" = 1 ]; then
    # The terminal goes away: end the reader of the bootstrap's output pipe and
    # wait until a write fails (SIGPIPE is ignored, so it fails with EPIPE, as a
    # write to a hung-up terminal fails with EIO).
    kill "$(cat "$STUB_DIR/reader.pid")" 2>/dev/null
    n=0
    while [ "$n" -lt 200 ]; do
        if ! echo probe 2>/dev/null; then echo "output cut" >> "$STUB_DIR/events.log"; break; fi
        sleep 0.05; n=$((n + 1))
    done
fi
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
    for f in gh sudo ps systemctl id findmnt lsblk journalctl dmesg sync sha256sum; do cp "$TEMPLATES/$f" "$CUR_SB/bin/$f"; done
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

# The real --help output of two released installers, for the capability check
# (_installer_can_reinstall). Made from the app repository's tags with:
#   git archive <tag> installers/standalone rso_terminal_installer/lib | tar -x -C <dir>
#   bash <dir>/installers/standalone/install_standalone.sh --help
# v0.4.9 is 737737d2, v0.5.0-rc.2 is 15c6bc81.
HELP_V049="$HERE/tests/fixtures/install_standalone_help_v0.4.9.txt"
HELP_RC2="$HERE/tests/fixtures/install_standalone_help_v0.5.0-rc.2.txt"

add_release() {  # add_release <tag> <its installer can reinstall: yes|no> [<--help text file>]
    local tag="$1" can="$2" help="${3:-}" src="$CUR_SB/src"
    [ -d "$src/.git" ] || sgit init -q "$src"
    mkdir -p "$src/installers/standalone" "$src/rso_core/tools" "$src/scripts"
    sed -e "s/@TAG@/$tag/g" -e "s/@CAN@/$can/g" -e "s|@HELP@|$help|g" "$TEMPLATES/installer" \
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

write_gui_wrapper() {  # write_gui_wrapper <install folder>: phase 55's renandstimpi-gui
    {
        echo '#!/bin/bash'
        echo '# MoreBees GUI (written by installers/standalone/modules/55-cli.sh).'
        echo 'if [ -x /usr/local/bin/rso-standalone-gui ]; then'
        echo '    exec /usr/local/bin/rso-standalone-gui "$@"'
        echo 'fi'
        echo "source \"$1/venv/bin/activate\""
        echo "cd \"$1\" || exit 1"
        echo "export PYTHONPATH=\"$1\""
        echo 'exec python -m renandstimpi.gui_launcher.app "$@"'
    } > "$CUR_SB/usr/local/bin/renandstimpi-gui"
}

unfinished_sandbox() {  # a Pi whose first install stopped after phase 55, before phase 70
    local h
    fresh_sandbox
    h="$CUR_SB/home"
    mkdir -p "$h/projects"
    sgit clone -q "$CUR_SB/remote.git" "$h/projects/RenAndStimPi"
    sgit -C "$h/projects/RenAndStimPi" remote set-url origin "https://github.com/JConeLab/RenAndStimPi.git"
    sgit -C "$h/projects/RenAndStimPi" checkout -q --detach v0.4.9
    write_gui_wrapper "$h/projects/RenAndStimPi"
}

installed_sandbox() {  # installed_sandbox <tag> <its installer can reinstall: yes|no> [<--help text file>]
    # A Pi installed at <tag> by the bootstrap: ~/rso/current and the install
    # folder ~/projects/RenAndStimPi, both fetching through the deploy key,
    # which works; the wrappers and the role file of phases 50, 55 and 70.
    local h
    new_sandbox real
    add_release v0.4.8 no
    add_release "$1" "$2" "${3:-}"
    sgit clone -q --bare "$CUR_SB/src" "$CUR_SB/remote.git"
    ln -s "$CUR_SB/remote.git" "$CUR_SB/alias.git"
    h="$CUR_SB/home"
    mkdir -p "$h/rso/releases" "$h/rso/shared/data" "$h/projects"
    sgit clone -q "git@github-rso:JConeLab/RenAndStimPi.git" "$h/rso/releases/$1"
    sgit -C "$h/rso/releases/$1" checkout -q --detach "$1"
    ln -s "$h/rso/releases/$1" "$h/rso/current"
    sgit clone -q "git@github-rso:JConeLab/RenAndStimPi.git" "$h/projects/RenAndStimPi"
    sgit -C "$h/projects/RenAndStimPi" checkout -q --detach "$1"
    write_gui_wrapper "$h/projects/RenAndStimPi"
    printf '#!/bin/bash\nexec "$HOME/rso/current/scripts/runtime/launch.sh" "$@"\n' \
        > "$CUR_SB/usr/local/bin/rso-standalone-gui"
    echo standalone > "$CUR_SB/etc/rso/role"
    mkdir -p "$h/rso/shared/venv/bin"
    cp "$TEMPLATES/python" "$h/rso/shared/venv/bin/python"
    chmod +x "$h/rso/shared/venv/bin/python"
}

# The seams for the NVMe check: a device-tree model, a boot folder, sysfs and
# /proc/cmdline that exist only when a test makes them, and a terminal that is a
# file of answers ($CUR_SB/tty) or, when there is no such file, none at all.
nvme_seams() {
    NVME_SEAMS=(MB_DT_MODEL="$CUR_SB/dt_model" MB_BOOT_DIR="$CUR_SB/boot/firmware"
                MB_SYSFS="$CUR_SB/sys" MB_PROC_CMDLINE="$CUR_SB/proc_cmdline" MB_TTY="$CUR_SB/tty"
                MB_BOOT_ID="$CUR_SB/boot_id")
}

run_bootstrap() {  # run_bootstrap [VAR=value ...] -- [bootstrap arguments ...]
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    if [ "${1:-}" = "--" ]; then shift; fi
    nvme_seams
    ( cd "$CUR_SB/home" && env -i HOME="$CUR_SB/home" PATH="$CUR_SB/bin:/usr/bin:/bin" \
          STUB_DIR="$CUR_SB" STUB_REAL_GIT="$REAL_GIT" TERM=dumb GIT_CONFIG_NOSYSTEM=1 \
          GIT_SSH_COMMAND=false MB_BIN_DIR="$CUR_SB/usr/local/bin" \
          MB_ROLE_FILE="$CUR_SB/etc/rso/role" MB_RIGCAM_ENV="$CUR_SB/etc/rso/rigcam.env" \
          "${NVME_SEAMS[@]}" ${envs[@]+"${envs[@]}"} "$BASH" "$SCRIPT" "$@" \
          <"$CUR_SB/stdin.txt" >"$CUR_SB/out.txt" 2>&1 )
    echo $? > "$CUR_SB/rc.txt"
}

run_bootstrap_cut() {  # run_bootstrap, with the output going away during the installer
    # stdout and stderr go to a pipe whose reader the installer stand-in ends
    # (STUB_CUT_OUTPUT=1), so every write after the installer fails.
    local envs=() reader
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    if [ "${1:-}" = "--" ]; then shift; fi
    mkfifo "$CUR_SB/out.fifo"
    cat "$CUR_SB/out.fifo" > "$CUR_SB/out.txt" &
    reader=$!
    echo "$reader" > "$CUR_SB/reader.pid"
    nvme_seams
    ( trap '' PIPE
      cd "$CUR_SB/home" && env -i HOME="$CUR_SB/home" PATH="$CUR_SB/bin:/usr/bin:/bin" \
          STUB_DIR="$CUR_SB" STUB_REAL_GIT="$REAL_GIT" TERM=dumb GIT_CONFIG_NOSYSTEM=1 \
          GIT_SSH_COMMAND=false MB_BIN_DIR="$CUR_SB/usr/local/bin" \
          MB_ROLE_FILE="$CUR_SB/etc/rso/role" MB_RIGCAM_ENV="$CUR_SB/etc/rso/rigcam.env" \
          "${NVME_SEAMS[@]}" STUB_CUT_OUTPUT=1 ${envs[@]+"${envs[@]}"} "$BASH" "$SCRIPT" "$@" \
          <"$CUR_SB/stdin.txt" >"$CUR_SB/out.fifo" 2>&1 )
    echo $? > "$CUR_SB/rc.txt"
    kill "$reader" 2>/dev/null
    wait "$reader" 2>/dev/null
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

echo "7b. a token from GH_TOKEN is not reported as signed out"
fresh_sandbox
touch "$CUR_SB/gh_session"; ln -s "$CUR_SB/remote.git" "$CUR_SB/https.git"
run_bootstrap GH_TOKEN=test-token -- --standalone
check "exit 0" rc_is 0
check "gh auth logout is not run against an environment token" no_event "gh auth logout"
check "says the token came from the environment" out_has "came from GH_TOKEN or GITHUB_TOKEN"
check "gh's credential-helper lines still removed" gh_helpers_gone
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
    if [ "$code" = 5 ]; then
        # 5 is the bootstrap's NVMe stop: an installer's own 5 must not look like it.
        check "installer exit 5: bootstrap exits 1, not the NVMe stop's 5" rc_is 1
    else
        check "installer exit $code: bootstrap exits $code" rc_is "$code"
    fi
    check "installer exit $code: says \"$text\"" out_has "$text"
    if [ "$code" = 5 ]; then
        check "installer exit 5: failure report" out_has "bootstrap failure report"
    else
        check "installer exit $code: no failure report" out_hasnt "bootstrap failure report"
    fi
    done_sb
done

echo "10b. terminal role: a status the wizard does not define gets the failure report"
fresh_sandbox
run_bootstrap STUB_INSTALLER_RC=2 -- --terminal
check "wizard exit 2: bootstrap exits 2" rc_is 2
check "wizard exit 2: failure report, not \"installed with problems\"" \
    eval 'out_has "the lab wizard stopped with status 2" && out_hasnt "installed with problems"'
done_sb

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

echo "16b. a refused reinstall after this run's own sign-in takes the token away"
installed_sandbox v0.4.9 no
add_release v0.5.0-rc.2 no
rm "$CUR_SB/alias.git"
run_bootstrap RSO_GIT_REF=v0.5.0-rc.2 -- --standalone
check "exit 3 with the guidance card" eval 'rc_is 3 && out_has "Reinstalling it needs a release"'
check "signed in, then out again" before "gh auth login" "gh auth logout"
check "the deploy key was not provisioned for a refused run" no_event "deploy-key setup"
check "the tags could not be listed through the deploy key: said so" out_has "could not be listed"
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

echo "21. an install that stopped before phase 70 is finished, not reinstalled"
unfinished_sandbox
run_bootstrap -- --standalone
check "only the wrapper: exit 0" rc_is 0
check "says it finishes an unfinished install" out_has "An unfinished MoreBees install was found; finishing it."
check "no reinstall card, no claim that nothing changes" \
    eval 'out_hasnt "Reinstalling it needs a release" && out_hasnt "changes nothing in ~/projects"'
check "the steps of a new Pi: sign-in, then the newest release's installer" \
    eval 'before "gh auth login" "installer ran" && call_has "RSO_GIT_REF=v0.4.9"'
check "... into the install folder" call_has "RSO_INSTALL_DIR=$CUR_SB/home/projects/RenAndStimPi"
done_sb
unfinished_sandbox
mkdir -p "$CUR_SB/home/rso/releases" "$CUR_SB/home/rso/shared/data"
echo standalone > "$CUR_SB/etc/rso/role"
run_bootstrap -- --standalone
check "the wrapper, ~/rso and the role but no ~/rso/current: finished too" \
    eval 'rc_is 0 && out_has "An unfinished MoreBees install was found" && event "installer ran"'
done_sb
unfinished_sandbox
mkdir -p "$CUR_SB/home/rso/shared/data"
run_bootstrap -- --standalone --only 40
check "--only on an unfinished Pi takes the same steps" \
    eval 'rc_is 0 && event "gh auth login" && call_has "arg=--only" && call_has "arg=40"'
done_sb
unfinished_sandbox
echo "4321 python3 -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 20
check "--only 20 on an unfinished Pi still refuses while MoreBees runs" \
    eval 'rc_is 3 && out_has "MoreBees is in use" && no_event "gh auth login"'
done_sb
new_sandbox stub
echo terminal > "$CUR_SB/etc/rso/role"
run_bootstrap -- --standalone
check "a role file alone that names another role: exit 3" \
    eval 'rc_is 3 && out_has "set up as a MoreBees terminal" && no_event "gh auth"'
done_sb
installed_sandbox v0.4.9 no
run_bootstrap -- --standalone
check "a provisioned Pi still takes the reinstall path" \
    eval 'rc_is 3 && out_has "already installed on this Pi (v0.4.9)" && out_has "Reinstalling it needs a release" && out_hasnt "unfinished"'
done_sb
installed_sandbox v0.4.9 no
rm "$CUR_SB/home/rso/current/installers/standalone/install_standalone.sh"
rm -rf "$CUR_SB/home/projects"
run_bootstrap -- --standalone --only 40
check "--only on a provisioned Pi with no installer to run: exit 3, nothing installed" \
    eval 'rc_is 3 && out_has "no standalone installer to run --only with" && no_event "gh auth login" && test ! -e "$CUR_SB/home/projects"'
done_sb

echo "22. --help and --dry-run on a provisioned Pi ask the installed release's installer"
installed_sandbox v0.4.9 no
add_release v0.5.0 yes
run_bootstrap -- --standalone --help
check "--help: exit 0 with the installer's help" eval 'rc_is 0 && out_has "--only <k[,k...]>"'
check "--help: no sudo, no sign-in, no reinstall card" \
    eval 'no_event "sudo " && no_event "gh auth" && out_hasnt "Reinstalling it needs a release"'
check "--help: no temporary copy was made" test ! -e "$CUR_SB/home/.cache/morebees"
done_sb
installed_sandbox v0.4.9 no
add_release v0.5.0 yes
run_bootstrap -- --standalone --dry-run --verbose
check "--dry-run: ~/rso/current's installer ran as the operator" \
    eval 'rc_is 0 && call_has "installer=$CUR_SB/home/rso/current/installers/standalone/install_standalone.sh" && no_event "sudo "'
check "--dry-run: the arguments, without --standalone" \
    test "$(grep '^arg=' "$CUR_SB/installer_call.txt" | tr '\n' ' ')" = "arg=--dry-run arg=--verbose "
check "--dry-run: no sign-in and no temporary copy" \
    eval 'no_event "gh auth" && test ! -e "$CUR_SB/home/.cache/morebees"'
done_sb

echo "23. a terminal that goes away during the installer does not change the exit status"
# An installer's failure other than 5, which the bootstrap keeps for the NVMe restart (it becomes 1).
for pair in "129|Interrupted. Run the same command again" "6|stopped with status 6" "0|is installed."; do
    code="${pair%%|*}"; text="${pair#*|}"
    fresh_sandbox
    run_bootstrap_cut STUB_INSTALLER_RC="$code" -- --standalone
    log="$(the_log)"
    check "installer exit $code, output gone: the writes after it failed" event "output cut"
    check "installer exit $code, output gone: bootstrap exits $code" rc_is "$code"
    check "installer exit $code, output gone: the log has the outcome and the status" \
        eval 'grep -qF "$text" "$log" && grep -q "bootstrap exit status: $code" "$log"'
    done_sb
done

echo "24. the temporary copy goes even when the installer left root's files in it"
if [ "$(/usr/bin/id -u)" = 0 ]; then
    echo "  skip - run as root, so nothing in the copy is out of the operator's reach"
else
    installed_sandbox v0.4.9 no
    add_release v0.5.0 yes
    run_bootstrap STUB_ROOT_FILES=1 -- --standalone --reinstall keep
    check "exit 0" rc_is 0
    check "the hand-off asks Python for no bytecode" call_has "PYTHONDONTWRITEBYTECODE=1"
    check "the operator could not remove it, so sudo did" \
        eval 'grep -qF "sudo rm -rf -- $CUR_SB/home/.cache/morebees/build." "$CUR_SB/events.log"'
    check "the temporary copy is gone" no_build_left
    check "the log says how it went" eval 'grep -q "temporary copy removed with sudo" "$(the_log)"'
    done_sb
fi
installed_sandbox v0.4.9 no
add_release v0.5.0 yes
run_bootstrap -- --standalone --reinstall keep
check "an ordinary run removes the copy without sudo" \
    eval 'no_build_left && no_event "sudo rm" && grep -q "temporary copy removed: " "$(the_log)"'
done_sb

echo "25. a successful hand-off forwards the reinstall options unchanged"
installed_sandbox v0.4.9 no
add_release v0.5.0 yes
run_bootstrap -- --standalone --reinstall delete --confirm-delete=rig-01 --inventory \
    --skip-phase 20 --allow-older-release --non-interactive
check "exit 0, to v0.5.0" eval 'rc_is 0 && call_has "RSO_GIT_REF=v0.5.0"'
check "every option, in order, without --standalone" \
    test "$(grep '^arg=' "$CUR_SB/installer_call.txt" | tr '\n' ' ')" = "arg=--reinstall arg=delete arg=--confirm-delete=rig-01 arg=--inventory arg=--skip-phase arg=20 arg=--allow-older-release arg=--non-interactive "
done_sb
installed_sandbox v0.5.0 yes
add_release v0.5.1 yes
sgit -C "$CUR_SB/home/rso/current" fetch -q --tags origin
sgit -C "$CUR_SB/home/rso/current" checkout -q --detach v0.5.1
run_bootstrap RSO_GIT_REF=v0.5.0 -- --standalone --allow-older-release --reinstall keep
check "an older release with --allow-older-release: handed off to it" \
    eval 'rc_is 0 && call_has "release=v0.5.0" && call_has "RSO_GIT_REF=v0.5.0"'
check "... with --allow-older-release forwarded" \
    test "$(grep '^arg=' "$CUR_SB/installer_call.txt" | tr '\n' ' ')" = "arg=--allow-older-release arg=--reinstall arg=keep "
done_sb

echo "26. the capability check against the real --help text of released installers"
installed_sandbox v0.4.9 no "$HELP_V049"
add_release v0.5.0-rc.2 no "$HELP_RC2"
run_bootstrap RSO_GIT_REF=v0.5.0-rc.2 -- --standalone --reinstall keep
check "v0.5.0-rc.2's real usage text: not a reinstall-capable installer" \
    eval 'rc_is 3 && out_has "Reinstalling it needs a release" && no_event "installer ran"'
done_sb
installed_sandbox v0.4.9 no "$HELP_V049"
run_bootstrap -- --standalone
check "v0.4.9's real usage text: not the target, and no newer release: the card" \
    eval 'rc_is 3 && out_has "MoreBees v0.4.9 is installed on this Pi." && no_event "installer ran"'
done_sb

# --- 27 to 56: the NVMe power settings on a Raspberry Pi 5 ------------------------

NL=$'\n'
PI5_LINE='console=serial0,115200 console=tty1 root=PARTUUID=0a1b2c3d-02 rootfstype=ext4 fsck.repair=yes rootwait quiet splash plymouth.ignore-serial-consoles'
NVME_ADDED='nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off'
KC3000='KINGSTON SKC3000S512G'        # a model known to disconnect, as sysfs names it
OTHER_DRIVE='Samsung SSD 980 1TB'     # a model the bootstrap knows nothing about

as_pi5_nvme() {  # as_pi5_nvme <drive model>: the sandbox is a Pi 5 whose root is on this NVMe drive
    local b="$CUR_SB/boot/firmware"
    printf 'Raspberry Pi 5 Model B Rev 1.1\0' > "$CUR_SB/dt_model"
    echo /dev/nvme0n1p2 > "$CUR_SB/root_source"
    mkdir -p "$CUR_SB/sys/block/nvme0n1/device" "$b"
    echo "$1" > "$CUR_SB/sys/block/nvme0n1/device/model"
    # As on the lab's Pi 5, the boot line has no newline at its end.
    printf '%s' "$PI5_LINE" > "$b/cmdline.txt"
    printf 'reboot=w coherent_pool=1M 8250.nr_uarts=1 %s\n' "$PI5_LINE" > "$CUR_SB/proc_cmdline"
    echo 0c1b0e1d-0000-4000-8000-000000000001 > "$CUR_SB/boot_id"
}
pending_file() { echo "$CUR_SB/home/.local/state/morebees/nvme-restart-pending"; }
restarted() {  # restarted <with the settings: yes|no>: a new boot, from the line or not
    echo 0c1b0e1d-0000-4000-8000-000000000002 > "$CUR_SB/boot_id"
    if [ "$1" = yes ]; then
        printf 'reboot=w %s\n' "$(cat "$CUR_SB/boot/firmware/cmdline.txt")" > "$CUR_SB/proc_cmdline"
    fi
}
event_before() {  # event_before <a> <b>: the first event holding a comes before the first holding b
    local la lb
    la="$(grep -nF -- "$1" "$CUR_SB/events.log" | head -n 1 | cut -d: -f1)"
    lb="$(grep -nF -- "$2" "$CUR_SB/events.log" | head -n 1 | cut -d: -f1)"
    [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]
}
keep_line() { cp "$CUR_SB/boot/firmware/cmdline.txt" "$CUR_SB/line_before"; }
line_kept() { cmp -s "$CUR_SB/line_before" "$CUR_SB/boot/firmware/cmdline.txt"; }
line_is()   {  # line_is <bytes>: the boot line is exactly these bytes
    printf '%s' "$1" > "$CUR_SB/line_want"
    cmp -s "$CUR_SB/line_want" "$CUR_SB/boot/firmware/cmdline.txt"
}
boot_files() {  # the names in the boot folder, each followed by a space
    local f out=""
    for f in "$CUR_SB"/boot/firmware/* "$CUR_SB"/boot/firmware/.[!.]*; do
        if [ -e "$f" ]; then out="$out${f##*/} "; fi
    done
    printf '%s' "$out"
}
sha_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
run_undo() {  # run_undo <command>: the undo as an operator pastes it, in the sandbox; its status in undo_rc.txt
    ( cd "$CUR_SB/home" && env -i HOME="$CUR_SB/home" PATH="$CUR_SB/bin:/usr/bin:/bin" STUB_DIR="$CUR_SB" \
          "$BASH" -c "$1" >"$CUR_SB/undo_out.txt" 2>&1 )
    echo $? > "$CUR_SB/undo_rc.txt"
}
undo_of() { sed -n 's/^  \(printf .*\)$/\1/p' "$CUR_SB/out.txt" | head -n 1; }
asked()  { out_has "Add them now?"; }

echo "27. a Pi 5 that starts from a drive known to disconnect: the settings are added, then a stop for a restart"
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
printf '\n' > "$CUR_SB/tty"         # a terminal, where a question would be answered with Enter
run_bootstrap -- --standalone
log="$(the_log)"
b="$CUR_SB/boot/firmware"
undo="printf '%s  %s\n' $(sha_of "$b/cmdline.txt") $b/cmdline.txt $(sha_of "$CUR_SB/line_before") $b/cmdline.txt.before-morebees-nvme | sha256sum -c --quiet && sudo cp $b/cmdline.txt.before-morebees-nvme $b/cmdline.txt && sudo sync -- $b/cmdline.txt $b"
check "exit 5" rc_is 5
check "the boot line is the old line plus the three settings, byte for byte, still with no newline" \
    line_is "$PI5_LINE $NVME_ADDED"
check "the old line is kept beside it" cmp -s "$CUR_SB/line_before" "$b/cmdline.txt.before-morebees-nvme"
check "nothing else is left in the boot folder" test "$(boot_files)" = "cmdline.txt cmdline.txt.before-morebees-nvme "
check "before the first sudo, it says what it adds and why" \
    out_has "Adding $NVME_ADDED to the boot line ($b/cmdline.txt), because this drive ($KC3000) is a model known to disconnect without them; sudo may ask for your password."
check "one line says what changed and why" \
    out_has "Added $NVME_ADDED to the boot line ($b/cmdline.txt), because this drive ($KC3000) is a model known to disconnect without them."
check "the undo, on a line of its own, puts the old line back only while the line and its copy are as written" \
    eval 'out_has "To undo, run this, which puts the old line back only while the boot line and its copy are as written here, then restart the Pi:" && grep -qxF "  $undo" "$CUR_SB/out.txt"'
check "the log has both SHA-256 sums and the undo command" \
    eval 'grep -qF "sha256 before $(sha_of "$CUR_SB/line_before"), after $(sha_of "$b/cmdline.txt")" "$log" && grep -qF "undo command: $undo" "$log"'
check "the restart is recorded for this boot and this line" \
    test "$(cat "$(pending_file)")" = "$(cat "$CUR_SB/boot_id") $(sha_of "$b/cmdline.txt")"
check "the new line and its copy were written through to the drive before the move" \
    eval 'event_before "sudo sync -- $b/cmdline.txt.morebees-new." "sudo mv -f -- $b/cmdline.txt.morebees-new." && grep -F "sudo sync -- $b/cmdline.txt.morebees-new." "$CUR_SB/events.log" | grep -qF " $b/cmdline.txt.before-morebees-nvme"'
check "after the move, the line and then the folder were written through to the drive; no plain sync" \
    eval 'event_before "sudo mv -f -- $b/cmdline.txt.morebees-new." "sudo sync -- $b/cmdline.txt $b" && grep -qxF "sudo sync -- $b/cmdline.txt $b" "$CUR_SB/events.log" && ! grep -qxF "sync " "$CUR_SB/events.log"'
check "nothing was asked, though a terminal was there" eval '! asked'
check "says to restart, then run the same command again" out_has "Restart the Pi (sudo reboot), then run the same command again."
check "stopped before the sign-in, the clone and the installer" \
    eval 'no_event "gh auth" && test ! -e "$CUR_SB/clone_attempted" && no_event "installer ran"'
check "the new line was moved into place with sudo" event "sudo mv -f -- $b/cmdline.txt.morebees-new."
: > "$CUR_SB/events.log"
run_undo "$undo"
check "the undo, pasted as printed, puts the old line back and writes it through" \
    eval 'cmp -s "$CUR_SB/line_before" "$b/cmdline.txt" && event "sudo sync -- $b/cmdline.txt $b"'
done_sb

echo "28. this boot's kernel log shows a drive disconnecting: the same, for a drive not on the list"
new_sandbox stub
as_pi5_nvme "$OTHER_DRIVE"
printf '%s\n' "[    1.9] nvme nvme0: pci function 0001:01:00.0" \
    "[  311.2] nvme nvme0: controller is down; will reset: CSTS=0xffffffff, PCI_STATUS=0x10" > "$CUR_SB/journal.log"
printf '\n' > "$CUR_SB/tty"
run_bootstrap -- --standalone
check "from the journal: exit 5, the settings added, nothing asked" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && ! asked'
check "... read from this boot's kernel messages" event "journalctl -k -b 0"
check "... and says why" out_has "because this boot's kernel log shows the drive disconnecting (controller is down)"
done_sb
new_sandbox stub
as_pi5_nvme "$OTHER_DRIVE"
echo "[  311.2] nvme nvme0: controller is down; will reset: CSTS=0xffffffff, PCI_STATUS=0x10" > "$CUR_SB/dmesg.log"
printf '\n' > "$CUR_SB/tty"
run_bootstrap -- --standalone
check "an empty journal: read from the kernel's buffer, exit 5, the settings added, nothing asked" \
    eval 'event "dmesg" && rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && ! asked'
done_sb

echo "29. any other drive: the bootstrap asks, and the answer is No unless it is y"
fresh_sandbox
as_pi5_nvme "$OTHER_DRIVE"
keep_line
printf '\n' > "$CUR_SB/tty"         # a terminal, and the operator presses Enter
run_bootstrap -- --standalone
check "asked, with No as the default" out_has "Add them now? This run then stops so that you can restart the Pi. [y/N]"
check "Enter: the boot line and the boot folder are as they were" eval 'line_kept && test "$(boot_files)" = "cmdline.txt "'
check "Enter: the run carries on to the installer, exit 0" eval 'rc_is 0 && event "installer ran"'
check "Enter: the answer is logged" eval 'grep -qF "asked; answer []: no" "$(the_log)"'
check "Enter: says how to add them later" out_has "To add the settings later, run again with --add-nvme-power-settings."
done_sb
new_sandbox stub
as_pi5_nvme "$OTHER_DRIVE"
printf 'y\n' > "$CUR_SB/tty"
run_bootstrap -- --standalone
check "y: exit 5, the settings added" eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED"'
check "y: the answer is logged and given as the reason" \
    eval 'grep -qF "asked; answer [y]: yes" "$(the_log)" && out_has "because you answered yes"'
done_sb

echo "30. no terminal to ask on: nothing changes, unless --add-nvme-power-settings asks for the settings"
fresh_sandbox
as_pi5_nvme "$OTHER_DRIVE"
keep_line
run_bootstrap -- --standalone
check "no terminal: not asked, the boot line as it was, the run carries on" \
    eval '! asked && line_kept && rc_is 0 && event "installer ran"'
check "no terminal: says how to add them" \
    out_has "There is no terminal to ask on, so the boot line was not changed. To add them, run again with --add-nvme-power-settings."
done_sb
new_sandbox stub
as_pi5_nvme "$OTHER_DRIVE"
run_bootstrap -- --standalone --add-nvme-power-settings
check "--add-nvme-power-settings with no terminal: exit 5, the settings added, nothing asked" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && ! asked'
check "... and it says why" out_has "because --add-nvme-power-settings asked for them"
done_sb
fresh_sandbox
run_bootstrap -- --standalone --add-nvme-power-settings
check "not a Pi 5: the flag adds nothing, says why, and the install carries on" \
    eval 'rc_is 0 && out_has "--add-nvme-power-settings: nothing to add, because this is not a Raspberry Pi 5" && event "installer ran"'
check "the flag is the bootstrap's own: the installer does not get it" \
    eval '! grep -q "^arg=--add-nvme-power-settings$" "$CUR_SB/installer_call.txt"'
check "no shell error about the missing device-tree file" out_hasnt "No such file or directory"
done_sb

echo "31. an SD card, a USB drive, a Pi 4, or a boot line with the settings: nothing changes, nothing is asked"
for pair in "sd|the root filesystem is on /dev/mmcblk0p2, not on an NVMe drive" \
            "usb|the root filesystem is on /dev/sda2, not on an NVMe drive" \
            "pi4|this is not a Raspberry Pi 5 (model: Raspberry Pi 4 Model B Rev 1.5)" \
            "set|the boot line already has all three settings"; do
    what="${pair%%|*}"; why="${pair#*|}"
    fresh_sandbox
    as_pi5_nvme "$KC3000"               # a drive known to disconnect ...
    printf 'y\n' > "$CUR_SB/tty"        # ... and a terminal that would answer yes
    case "$what" in
        sd)  echo /dev/mmcblk0p2 > "$CUR_SB/root_source" ;;
        usb) echo /dev/sda2 > "$CUR_SB/root_source" ;;
        pi4) printf 'Raspberry Pi 4 Model B Rev 1.5\0' > "$CUR_SB/dt_model" ;;
        set) printf '%s %s\n' "$PI5_LINE" "$NVME_ADDED" > "$CUR_SB/boot/firmware/cmdline.txt"
             printf 'reboot=w %s %s\n' "$PI5_LINE" "$NVME_ADDED" > "$CUR_SB/proc_cmdline" ;;
    esac
    keep_line
    run_bootstrap -- --standalone
    check "$what: exit 0, the installer ran" eval 'rc_is 0 && event "installer ran"'
    check "$what: nothing asked, nothing changed, no copy made" \
        eval '! asked && out_hasnt "Added " && line_kept && test "$(boot_files)" = "cmdline.txt "'
    check "$what: the log says why" eval 'grep -qF "NVMe power settings: nothing to do: $why" "$(the_log)"'
    done_sb
done

echo "32. only the settings the line lacks are added; the rest stays byte for byte"
new_sandbox stub
as_pi5_nvme "$KC3000"
line32="$(printf 'console=tty1  root=PARTUUID=0a1b2c3d-02\trootwait pcie_aspm=off quiet')"
printf '%s\n' "$line32" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "exit 5" rc_is 5
check "the two missing settings at the end; two spaces, a tab and the newline as they were" \
    line_is "$line32 nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off$NL"
check "the line names only those two" out_has "Added nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off to the boot line"
check "the old line is kept" cmp -s "$CUR_SB/line_before" "$CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme"
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
printf '%s ' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt"
run_bootstrap -- --standalone
check "a line that ends in a space gets no second space" line_is "$PI5_LINE $NVME_ADDED"
done_sb

echo "33. an earlier copy of the boot line is never overwritten"
new_sandbox stub
as_pi5_nvme "$KC3000"
printf 'an older boot line' > "$CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme"
keep_line
run_bootstrap -- --standalone
dated=""
for f in "$CUR_SB"/boot/firmware/cmdline.txt.before-morebees-nvme-*; do
    if [ -e "$f" ]; then dated="$f"; fi
done
check "exit 5, the settings added" eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED"'
check "a copy that holds another line is left as it was" \
    test "$(cat "$CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme")" = "an older boot line"
check "this line is copied beside it under a dated name" cmp -s "$CUR_SB/line_before" "${dated:-$CUR_SB/no-dated-copy}"
check "the undo names that copy" out_has "&& sudo cp ${dated:-<no dated copy>} $CUR_SB/boot/firmware/cmdline.txt && sudo sync --"
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
cp "$CUR_SB/boot/firmware/cmdline.txt" "$CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme"
run_bootstrap -- --standalone
check "a copy that holds this very line is used as it is, not written again" \
    eval 'rc_is 5 && no_event "sudo cp -- $CUR_SB/boot/firmware/cmdline.txt $CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme" && test "$(boot_files)" = "cmdline.txt cmdline.txt.before-morebees-nvme "'
done_sb

echo "34. a check that fails changes nothing; where the settings are wanted, the run stops (3) and says how to add them"
for pair in "two lines|has more than one line" \
            "a Windows line ending|has a Windows line ending" \
            "a failed flush|could not be written through to the drive" \
            "a failed move|could not be moved to"; do
    what="${pair%%|*}"; why="${pair#*|}"
    new_sandbox stub
    as_pi5_nvme "$KC3000"
    stub_env="STUB_SUDO_FAIL="
    case "$what" in
        "two lines") printf '%s\nsecond line\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt" ;;
        "a Windows line ending") printf '%s\r\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt" ;;
        "a failed flush") stub_env="STUB_SUDO_FAIL=sync" ;;
        "a failed move") stub_env="STUB_SUDO_FAIL=mv" ;;
    esac
    keep_line
    run_bootstrap "$stub_env" -- --standalone
    check "$what: says why" out_has "$why"
    check "$what: the boot line as it was, no copy or temporary file left" \
        eval 'line_kept && test "$(boot_files)" = "cmdline.txt "'
    check "$what: exit 3 before the sign-in and the installer, with the settings to add by hand" \
        eval 'rc_is 3 && no_event "gh auth" && no_event "installer ran" && out_has "To add them by hand, put these at the end of the one line in"'
    check "$what: no restart is recorded" test ! -e "$(pending_file)"
    done_sb
done
fresh_sandbox
as_pi5_nvme "$KC3000"
printf '%s pcie_aspm=force\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "another value on the line, on a drive known to disconnect: left to the operator, and exit 3 before the installer" \
    eval 'out_has "sets pcie_aspm=force, which the bootstrap leaves to you" && line_kept && rc_is 3 && no_event "installer ran"'
check "... with how to edit the line, and the flag that goes on without them" \
    eval 'out_has "so that it holds $NVME_ADDED, with no other value for them" && out_has "run the same command with --no-nvme-power-settings"'
done_sb
fresh_sandbox
as_pi5_nvme "$OTHER_DRIVE"
printf '%s pcie_aspm=force\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "another value on the line, on a drive not on the list: left to the operator, and the run carries on, exit 0" \
    eval 'out_has "sets pcie_aspm=force, which the bootstrap leaves to you" && line_kept && rc_is 0 && event "installer ran"'
done_sb
fresh_sandbox
as_pi5_nvme "$OTHER_DRIVE"
printf '%s\r\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "a drive not on the list and a line it will not read: said, and the run carries on, exit 0" \
    eval 'out_has "The NVMe power settings were not checked" && line_kept && rc_is 0 && event "installer ran"'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
run_bootstrap STUB_EDIT_BOOT_ON=mktemp -- --standalone
check "an edit while the new line is prepared: says why, and that edit is all the line has" \
    eval 'out_has "changed while the new line was prepared" && line_is "$PI5_LINE edited"'
check "... no copy or temporary file left, exit 3 before the installer" \
    eval 'test "$(boot_files)" = "cmdline.txt " && rc_is 3 && no_event "installer ran"'
done_sb

echo "35. a provisioned Pi 5: the same check before an --only run or a reinstall hands off"
installed_sandbox v0.4.9 no
as_pi5_nvme "$KC3000"
run_bootstrap -- --standalone --only 90
check "--only: exit 5, the settings added, no installer ran" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && no_event "installer ran"'
done_sb
installed_sandbox v0.4.9 no
add_release v0.5.0 yes
as_pi5_nvme "$KC3000"
run_bootstrap -- --standalone --reinstall keep
check "a reinstall: exit 5 before the release is chosen, copied or handed off" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && no_event "installer ran" && test ! -e "$CUR_SB/home/.cache/morebees"'
done_sb
installed_sandbox v0.4.9 no
as_pi5_nvme "$KC3000"
keep_line
echo "4321 python3 -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 75
check "--only while MoreBees runs: its refusal first, exit 3, the boot line as it was" \
    eval 'rc_is 3 && out_has "MoreBees is in use" && line_kept'
rm "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 75
check "... and once it has stopped, the same command adds the settings" eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED"'
done_sb
installed_sandbox v0.4.9 no
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap -- --standalone --only 90 --dry-run
check "--dry-run: the boot line as it was, and the log says it was not checked" \
    eval 'rc_is 0 && line_kept && grep -qF "NVMe power settings: not checked: --help and --dry-run change nothing" "$(the_log)"'
done_sb

echo "36. a Ctrl+C before the move leaves no temporary file, and the same command finishes; one after it is held off"
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap STUB_SUDO_INTERRUPT=sync -- --standalone
check "interrupted while the files are written through: exit 130, the boot line as it was" eval 'rc_is 130 && line_kept'
check "only the copy of the line is left in the boot folder, and no restart is recorded" \
    eval 'test "$(boot_files)" = "cmdline.txt cmdline.txt.before-morebees-nvme " && test ! -e "$(pending_file)"'
run_bootstrap -- --standalone
check "the same command again: exit 5, the settings added, the copy still the old line" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && cmp -s "$CUR_SB/line_before" "$CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme"'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
run_bootstrap STUB_SUDO_INTERRUPT_AFTER=mv -- --standalone
log="$(the_log)"
check "a Ctrl+C just after the move waits for the stop: exit 5, the settings added" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED"'
check "... the log has the line after and the undo command, and the restart is recorded" \
    eval 'grep -qF "NVMe power settings: line after:  $PI5_LINE $NVME_ADDED" "$log" && grep -qF "undo command: printf" "$log" && test -s "$(pending_file)"'
check "... and the screen says to restart" out_has "Restart the Pi (sudo reboot), then run the same command again."
done_sb

echo "37. settings on the boot line that the running system did not start with"
fresh_sandbox
as_pi5_nvme "$OTHER_DRIVE"
printf '%s %s' "$PI5_LINE" "$NVME_ADDED" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "a drive not on the list: says a restart is still to come, changes nothing, and carries on" \
    eval 'out_has "but this system did not start with them: restart the Pi to use them." && line_kept && rc_is 0 && event "installer ran"'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
printf '%s %s' "$PI5_LINE" "$NVME_ADDED" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "a drive known to disconnect: exit 3 before the installer, the line as it was" \
    eval 'rc_is 3 && out_has "they are wanted because this drive ($KC3000) is a model known to disconnect" && line_kept && no_event "installer ran"'
done_sb

echo "38. the same command again without the restart stops again; after the restart, the run goes on"
new_sandbox stub
as_pi5_nvme "$KC3000"
run_bootstrap -- --standalone
check "first run: exit 5, the restart recorded for this boot" \
    eval 'rc_is 5 && test "$(cut -d" " -f1 "$(pending_file)")" = "$(cat "$CUR_SB/boot_id")"'
: > "$CUR_SB/events.log"
run_bootstrap -- --standalone
check "again in the same boot: exit 5, it says the Pi has not restarted, and nothing else ran" \
    eval 'rc_is 5 && out_has "but the Pi has not restarted since" && no_event "gh auth" && no_event "installer ran" && test ! -e "$CUR_SB/clone_attempted"'
done_sb
fresh_sandbox
as_pi5_nvme "$KC3000"
run_bootstrap -- --standalone
restarted yes
run_bootstrap -- --standalone
check "after a restart that started with them: the install goes on, exit 0, and the record is gone" \
    eval 'rc_is 0 && event "installer ran" && test ! -e "$(pending_file)"'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
run_bootstrap -- --standalone
restarted no
run_bootstrap -- --standalone
check "after a restart that did not start with them: the Pi does not start from this line; exit 3" \
    eval 'rc_is 3 && out_has "it does not start from $CUR_SB/boot/firmware/cmdline.txt" && out_has "cmdline= or os_prefix="'
done_sb

echo "39. the checks around the move: a copy or a line that does not read back changes nothing"
for pair in "staged|did not read back as the old line plus" \
            "moved|did not read back as written, so its copy was put back"; do
    what="${pair%%|*}"; why="${pair#*|}"
    new_sandbox stub
    as_pi5_nvme "$KC3000"
    keep_line
    run_bootstrap STUB_CORRUPT="$what" -- --standalone
    check "$what: says why, exit 3" eval 'out_has "$why" && rc_is 3'
    check "$what: the boot line byte for byte as before, nothing left in the boot folder" \
        eval 'line_kept && test "$(boot_files)" = "cmdline.txt "'
    check "$what: no restart recorded" test ! -e "$(pending_file)"
    done_sb
done
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap STUB_CORRUPT=restore -- --standalone
check "a line that does not read back, and a copy that cannot be put back: exit 1, with the command to put it back" \
    eval 'rc_is 1 && out_has "and its copy could not be put back" && out_has "put it back with: sudo cp $CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme"'
check "... and the copy is still there to put back" cmp -s "$CUR_SB/line_before" "$CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme"
done_sb

echo "40. a boot line the bootstrap will not read: on a drive known to disconnect, exit 3 with the reason; an empty one stops on any drive"
if [ "$(id -u)" = 0 ]; then echo "   (as root: the unreadable boot line is skipped)"; fi
for pair in "a NUL byte|holds a byte that is not text" "a link|is a link" "unreadable|cannot be read"; do
    what="${pair%%|*}"; why="${pair#*|}"
    if [ "$what" = unreadable ] && [ "$(id -u)" = 0 ]; then continue; fi
    new_sandbox stub
    as_pi5_nvme "$KC3000"
    b="$CUR_SB/boot/firmware"
    case "$what" in
        "a NUL byte") printf '%s\0x' "$PI5_LINE" > "$b/cmdline.txt" ;;
        "a link") mv "$b/cmdline.txt" "$b/cmdline.real"; ln -s cmdline.real "$b/cmdline.txt" ;;
        unreadable) chmod 000 "$b/cmdline.txt" ;;
    esac
    run_bootstrap -- --standalone
    chmod 644 "$b/cmdline.txt" 2>/dev/null || true
    check "$what: says why, exit 3 before the installer, with the settings to add by hand" \
        eval 'out_has "$why" && rc_is 3 && no_event "installer ran" && out_has "$NVME_ADDED"'
    check "$what: nothing was made in the boot folder" \
        eval 'test ! -e "$b/cmdline.txt.before-morebees-nvme" && ! ls "$b" | grep -q morebees-new'
    done_sb
done
for what in empty "only spaces" "only newlines"; do
    for drive in "$KC3000" "$OTHER_DRIVE"; do
        new_sandbox stub
        as_pi5_nvme "$drive"
        b="$CUR_SB/boot/firmware"
        case "$what" in
            empty) : > "$b/cmdline.txt" ;;
            "only spaces") printf '   \n' > "$b/cmdline.txt" ;;
            "only newlines") printf '\n\n' > "$b/cmdline.txt" ;;
        esac
        run_bootstrap -- --standalone
        check "$what, $drive: exit 3 before the installer; the Pi would not start from it, and no restart or settings are advised" \
            eval 'rc_is 3 && no_event "installer ran" && out_has "is empty: the Pi would not start from it. Do not restart the Pi until a working line is back." && out_hasnt "sudo reboot" && out_hasnt "To add them by hand"'
        check "$what, $drive: nothing was made in the boot folder" \
            eval 'test ! -e "$b/cmdline.txt.before-morebees-nvme" && ! ls "$b" | grep -q morebees-new'
        done_sb
    done
done
new_sandbox stub
as_pi5_nvme "$OTHER_DRIVE"
b="$CUR_SB/boot/firmware"
cp "$b/cmdline.txt" "$b/cmdline.txt.before-morebees-nvme"
: > "$b/cmdline.txt"
run_bootstrap -- --standalone --no-nvme-power-settings
check "an empty line and --no-nvme-power-settings: still exit 3, naming the copy to put back after a check of its root=" \
    eval 'rc_is 3 && no_event "installer ran" && out_has "is in $b/cmdline.txt.before-morebees-nvme: check that its root= names this Pi" && out_has "sudo cp $b/cmdline.txt.before-morebees-nvme $b/cmdline.txt && sudo sync --"'
done_sb

echo "41. a copy of the line that fails part way leaves nothing under the copy's name"
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap STUB_CP_PARTIAL=1 -- --standalone
check "exit 3, says why, the line as it was" eval 'rc_is 3 && out_has "could not be copied to" && line_kept'
check "no partial copy left" test "$(boot_files)" = "cmdline.txt "
done_sb

echo "42. a provisioned Pi 5 while MoreBees runs: the boot line is not changed"
installed_sandbox v0.4.9 no
as_pi5_nvme "$KC3000"
keep_line
echo "4321 python3 -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 40
check "a drive known to disconnect, a phase the busy check does not cover: exit 3, the line as it was" \
    eval 'rc_is 3 && line_kept && no_event "installer ran" && out_has "take effect only after a restart, which would end it"'
done_sb
installed_sandbox v0.4.9 no
as_pi5_nvme "$OTHER_DRIVE"
keep_line
printf 'y\n' > "$CUR_SB/tty"
echo "4321 python3 -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 40
check "any other drive: not asked, the line as it was, and the --only run goes on" \
    eval '! asked && line_kept && rc_is 0 && event "installer ran" && out_has "MoreBees is in use, and the settings take effect only after a restart"'
done_sb

echo "43. a root on LVM or LUKS over an NVMe drive is found through the device stack"
new_sandbox stub
as_pi5_nvme "$KC3000"
echo /dev/mapper/cryptroot > "$CUR_SB/root_source"
printf 'cryptroot crypt\nnvme0n1p2 part\nnvme0n1 disk\n' > "$CUR_SB/lsblk.txt"
run_bootstrap -- --standalone
check "LUKS over NVMe: exit 5, the settings added, the disk read through lsblk" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && event "lsblk -nlso NAME,TYPE /dev/mapper/cryptroot"'
done_sb
fresh_sandbox
as_pi5_nvme "$KC3000"
echo /dev/mapper/vg-root > "$CUR_SB/root_source"
printf 'vg-root lvm\nsda2 part\nsda disk\n' > "$CUR_SB/lsblk.txt"
keep_line
run_bootstrap -- --standalone
check "LVM over a USB drive: not NVMe, nothing changed, the install goes on" \
    eval 'rc_is 0 && line_kept && grep -qF "the root filesystem is on /dev/mapper/vg-root, not on an NVMe drive" "$(the_log)"'
done_sb

echo "44. the line is read as the kernel reads it: - and _ alike in a name, and a bare --"
fresh_sandbox
as_pi5_nvme "$KC3000"
printf '%s pcie-aspm=force\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "pcie-aspm=force is the setting pcie_aspm: left to the operator; on a drive known to disconnect, exit 3" \
    eval 'out_has "sets pcie-aspm=force" && line_kept && rc_is 3'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
line44="$PI5_LINE nvme_core.default-ps-max-latency-us=0"
printf '%s' "$line44" > "$CUR_SB/boot/firmware/cmdline.txt"
run_bootstrap -- --standalone
check "a setting spelled with - counts: only the other two are added" \
    eval 'rc_is 5 && line_is "$line44 pcie_aspm=off pcie_port_pm=off"'
done_sb
fresh_sandbox
as_pi5_nvme "$KC3000"
printf '%s -- %s\n' "$PI5_LINE" "$NVME_ADDED" > "$CUR_SB/boot/firmware/cmdline.txt"
keep_line
run_bootstrap -- --standalone
check "settings after a bare -- go to init: the line is left as it is; on a drive known to disconnect, exit 3" \
    eval 'out_has "has a bare --" && line_kept && rc_is 3 && out_has "put these before the bare -- in"'
done_sb
fresh_sandbox
as_pi5_nvme "$KC3000"
printf '%s %s -- init_arg\n' "$PI5_LINE" "$NVME_ADDED" > "$CUR_SB/boot/firmware/cmdline.txt"
printf 'reboot=w %s %s -- init_arg\n' "$PI5_LINE" "$NVME_ADDED" > "$CUR_SB/proc_cmdline"
keep_line
run_bootstrap -- --standalone
check "all three before a bare --: nothing is missing, nothing said about the --, and the install goes on" \
    eval 'rc_is 0 && event "installer ran" && line_kept && out_hasnt "bare --"'
done_sb

echo "45. --non-interactive: nothing is asked, even with a terminal"
fresh_sandbox
as_pi5_nvme "$OTHER_DRIVE"
keep_line
printf 'y\n' > "$CUR_SB/tty"
run_bootstrap -- --standalone --non-interactive
check "not asked, the line as it was, the run goes on" \
    eval '! asked && line_kept && rc_is 0 && event "installer ran"'
check "... and it says how to add them" out_has "With --non-interactive nothing is asked"
done_sb

echo "46. --no-nvme-power-settings: nothing is added, asked or stopped for; with --add-nvme-power-settings, refused"
fresh_sandbox
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap -- --standalone --no-nvme-power-settings
check "a drive known to disconnect: the line as it was, the install goes on, exit 0" \
    eval 'line_kept && rc_is 0 && event "installer ran"'
check "... it says what that leaves" \
    out_has "--no-nvme-power-settings: the NVMe power settings were not added, although this drive ($KC3000) is a model known to disconnect without them."
check "... and the flag is the bootstrap's own: the installer does not get it" \
    eval '! grep -q "^arg=--no-nvme-power-settings$" "$CUR_SB/installer_call.txt"'
done_sb
fresh_sandbox
as_pi5_nvme "$KC3000"
run_bootstrap -- --standalone
run_bootstrap -- --standalone --no-nvme-power-settings
check "after a change, in the same boot: no second stop, the install goes on, exit 0" \
    eval 'rc_is 0 && event "installer ran"'
check "... and it says that this system did not start with them, and why they are wanted" \
    eval 'out_has "but this system did not start with them: they take effect only after a restart, and this install runs without them." && out_has "They are wanted because this drive ($KC3000) is a model known to disconnect"'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap -- --standalone --add-nvme-power-settings --no-nvme-power-settings
check "both flags: refused, exit 3, nothing changed or run" \
    eval 'rc_is 3 && line_kept && out_has "ask for opposite things" && no_event "gh auth" && no_event "installer ran"'
done_sb

echo "47. the undo, pasted as printed, refuses when the boot line or its copy changed since"
for what in line copy; do
    new_sandbox stub
    as_pi5_nvme "$KC3000"
    keep_line
    run_bootstrap -- --standalone
    b="$CUR_SB/boot/firmware"
    undo="$(undo_of)"
    case "$what" in
        line) printf ' edited' >> "$b/cmdline.txt" ;;
        copy) printf 'quiet splash' > "$b/cmdline.txt.before-morebees-nvme" ;;
    esac
    cp "$b/cmdline.txt" "$CUR_SB/line_now"
    : > "$CUR_SB/events.log"
    run_undo "$undo"
    check "$what changed: the undo fails its check and copies nothing" \
        eval 'test "$(cat "$CUR_SB/undo_rc.txt")" != 0 && grep -q FAILED "$CUR_SB/undo_out.txt" && cmp -s "$CUR_SB/line_now" "$b/cmdline.txt" && no_event "sudo cp"'
    done_sb
done

echo "48. the checks around the move, again: a copy that comes out wrong, a put-back that reads back wrong, a run that dies after the move"
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap STUB_CORRUPT=backup -- --standalone
check "a copy of the line that does not match it: exit 3, says why, the line as it was, no copy left" \
    eval 'rc_is 3 && out_has "does not match" && line_kept && test "$(boot_files)" = "cmdline.txt "'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap STUB_CORRUPT=putback -- --standalone
check "a line that does not read back, and a copy put back that does not either: exit 1, with the command to put it back" \
    eval 'rc_is 1 && out_has "and its copy could not be put back" && out_has "put it back with: sudo cp $CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme"'
done_sb
new_sandbox stub
as_pi5_nvme "$KC3000"
run_bootstrap STUB_SUDO_KILL_AFTER=mv -- --standalone
log="$(the_log)"
check "a run that dies just after the move: the log has the line after and the undo, and the restart is recorded" \
    eval 'line_is "$PI5_LINE $NVME_ADDED" && grep -qF "line after:  $PI5_LINE $NVME_ADDED" "$log" && grep -qF "undo command: printf" "$log" && test -s "$(pending_file)"'
done_sb

echo "49. a sudo that refuses: nothing else is asked of it, and nothing is left to remove"
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap STUB_SUDO_REFUSE_ALL=1 -- --standalone
check "exit 3, the line as it was, one sudo call, and no advice to remove a copy never made" \
    eval 'rc_is 3 && line_kept && test "$(grep -c "^sudo " "$CUR_SB/events.log")" = 1 && out_hasnt "could not remove"'
done_sb

echo "50. a move that sudo reports as failed although it happened: the change is taken as made"
new_sandbox stub
as_pi5_nvme "$KC3000"
keep_line
run_bootstrap STUB_SUDO_FAIL_AFTER=mv -- --standalone
check "exit 5, the new line in place, the copy and the record kept, and the log says why" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && cmp -s "$CUR_SB/line_before" "$CUR_SB/boot/firmware/cmdline.txt.before-morebees-nvme" && test -s "$(pending_file)" && grep -qF "mv ended with status 1" "$(the_log)"'
done_sb

echo "51. a temporary file that a power cut left in the boot folder goes before the next change"
new_sandbox stub
as_pi5_nvme "$KC3000"
printf 'a line from a run the power cut' > "$CUR_SB/boot/firmware/cmdline.txt.morebees-new.OLD123"
run_bootstrap -- --standalone
check "exit 5, and the boot folder holds only the line and its copy; the log names what was removed" \
    eval 'rc_is 5 && test "$(boot_files)" = "cmdline.txt cmdline.txt.before-morebees-nvme " && grep -qF "removed $CUR_SB/boot/firmware/cmdline.txt.morebees-new.OLD123" "$(the_log)"'
done_sb

echo "52. status 5 means only the restart: an installer's 5 on a --dry-run becomes 1"
installed_sandbox v0.4.9 no
run_bootstrap STUB_INSTALLER_RC=5 -- --standalone --dry-run
check "--dry-run on an installed Pi whose installer ends with 5: the bootstrap ends with 1" rc_is 1
done_sb

echo "53. no restart is advised while MoreBees runs"
installed_sandbox v0.4.9 no
as_pi5_nvme "$KC3000"
run_bootstrap -- --standalone --only 40
check "first run, MoreBees idle: exit 5, the settings added" eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED"'
echo "4321 python3 -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 40
check "again in the same boot while MoreBees runs: exit 3, what runs is named, and no sudo reboot" \
    eval 'rc_is 3 && out_has "MoreBees is in use, and a restart would end it" && out_has "4321" && out_hasnt "sudo reboot" && no_event "installer ran"'
done_sb
installed_sandbox v0.4.9 no
as_pi5_nvme "$KC3000"
printf '%s\r\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt"
echo "4321 python3 -m renandstimpi.gui_launcher.app" > "$CUR_SB/ps.txt"
run_bootstrap -- --standalone --only 40
check "a line it will not read while MoreBees runs: exit 3, and the restart waits for what runs" \
    eval 'rc_is 3 && out_has "once what is running has finished and MoreBees is closed, restart the Pi" && out_hasnt "sudo reboot"'
done_sb

echo "54. the restart record names the line it was made for"
new_sandbox stub
as_pi5_nvme "$KC3000"
b="$CUR_SB/boot/firmware"
run_bootstrap -- --standalone
cp "$b/cmdline.txt.before-morebees-nvme" "$b/cmdline.txt"     # the undo
restarted no                                                  # the Pi restarts from the old line
printf '%s  %s' "$PI5_LINE" "$NVME_ADDED" > "$b/cmdline.txt"  # the settings added by hand: another line
run_bootstrap -- --standalone
check "a record of another line is dropped: no claim that the Pi starts from elsewhere; exit 3, the plain reason" \
    eval 'rc_is 3 && out_hasnt "does not start from" && out_has "but this system did not start with them" && test ! -e "$(pending_file)"'
done_sb

echo "55. a restart that cannot be recorded: the stop says so"
new_sandbox stub
as_pi5_nvme "$KC3000"
mkdir -p "$(pending_file)"     # a folder where the record goes
run_bootstrap -- --standalone
check "exit 5, the settings added, and it says a run before the restart would not stop" \
    eval 'rc_is 5 && line_is "$PI5_LINE $NVME_ADDED" && out_has "could not record the restart it needs"'
done_sb

echo "56. --add-nvme-power-settings on a line it cannot change stops (3), like a drive known to disconnect"
for what in "a Windows line ending" "another value" "a bare --"; do
    fresh_sandbox
    as_pi5_nvme "$OTHER_DRIVE"
    case "$what" in
        "a Windows line ending") printf '%s\r\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt" ;;
        "another value") printf '%s pcie_aspm=force\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt" ;;
        "a bare --") printf '%s -- init_arg\n' "$PI5_LINE" > "$CUR_SB/boot/firmware/cmdline.txt" ;;
    esac
    keep_line
    run_bootstrap -- --standalone --add-nvme-power-settings
    check "$what: exit 3 before the installer, the line as it was, the flag given as the reason" \
        eval 'rc_is 3 && no_event "installer ran" && line_kept && out_has "they are wanted because --add-nvme-power-settings asked for them"'
    done_sb
done

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
