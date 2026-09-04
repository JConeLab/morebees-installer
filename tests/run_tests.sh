#!/usr/bin/env bash
# Bootstrap test suite — no framework, no network, no sudo.
#
# Scenario-catalog style (each test = one failure class), with PATH-stubbed
# git/gh so the real bootstrap code runs end-to-end up to the assertion.
# Run from the repo root:  bash tests/run_tests.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/bootstrap.sh"
PASS=0; FAIL=0

t_ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
t_fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

sandbox() {
    # Fresh HOME + stub bin dir; returns the sandbox path.
    local sb
    sb="$(mktemp -d)"
    mkdir -p "$sb/home" "$sb/bin"
    cat > "$sb/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "auth status") exit "${STUB_GH_AUTH_STATUS:-0}" ;;
    "auth login")  printf '%s\n' "${BROWSER:-UNSET}" > "$STUB_DIR/browser_seen"; exit 0 ;;
    "auth setup-git") exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$sb/bin/git" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *"refs/tags/v0.4.7"*) exit 0 ;;              # the v-prefixed tag exists
    *"refs/tags/0.4.7"*)  exit 2 ;;              # the bare pin does not
    *"clone"*) touch "$STUB_DIR/clone_attempted"; exit 1 ;;
    *"ls-remote"*) echo "deadbeef	HEAD"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$sb/bin/gh" "$sb/bin/git"
    echo "$sb"
}

run_bootstrap() {
    # run_bootstrap <sandbox> [env pairs...] -- captures combined output;
    # echoes exit code on the last line of the capture file's sibling.
    local sb="$1"; shift
    ( cd "$sb/home" && \
      env -i HOME="$sb/home" PATH="$sb/bin:/usr/bin:/bin" STUB_DIR="$sb" TERM=dumb "$@" \
          bash "$SCRIPT" --standalone >"$sb/out.txt" 2>&1 )
    echo $? > "$sb/rc.txt"
}

echo "1. syntax"
if bash -n "$SCRIPT"; then t_ok "bash -n clean"; else t_fail "bash -n"; fi

echo "2. curl|bash truncation armor (no top-level side effects)"
if [[ "$(tail -1 "$SCRIPT")" == 'main "$@"; exit $?' ]]; then
    t_ok "last line is the single entry point"
else
    t_fail "last line must be: main \"\$@\"; exit \$?"
fi
for n in 500 2000 8000; do
    sb="$(mktemp -d)"; mkdir -p "$sb/home"
    ( cd "$sb/home" && head -c "$n" "$SCRIPT" | env -i HOME="$sb/home" PATH=/usr/bin:/bin bash >/dev/null 2>&1 )
    if [[ ! -e "$sb/home/projects" ]]; then
        t_ok "truncated at $n bytes: no side effects"
    else
        t_fail "truncated at $n bytes CREATED ~/projects"
    fi
    rm -rf "$sb"
done

echo "3. typo'd release pin dies early with the did-you-mean hint"
sb="$(sandbox)"
run_bootstrap "$sb" RSO_GIT_REF=0.4.7 STUB_GH_AUTH_STATUS=0
rc="$(cat "$sb/rc.txt")"
if [[ "$rc" != 0 ]]; then t_ok "nonzero exit ($rc)"; else t_fail "expected failure, got exit 0"; fi
if grep -q "did you mean v0.4.7" "$sb/out.txt"; then
    t_ok "did-you-mean hint printed"
else
    t_fail "no did-you-mean hint. Output tail:"; tail -3 "$sb/out.txt" | sed 's/^/         /'
fi
if [[ ! -e "$sb/clone_attempted" ]]; then
    t_ok "died BEFORE any clone attempt"
else
    t_fail "clone was attempted despite the bad pin"
fi
if grep -q "step:  resolve-release" "$sb/out.txt" && grep -q "failure report" "$sb/out.txt"; then
    t_ok "failure report names the failing step"
else
    t_fail "no paste-able failure report"
fi
rm -rf "$sb"

echo "4. sign-in never launches a local browser (URL printed instead)"
sb="$(sandbox)"
run_bootstrap "$sb" RSO_GIT_REF=0.4.7 STUB_GH_AUTH_STATUS=1
if [[ "$(cat "$sb/browser_seen" 2>/dev/null)" == "echo" ]]; then
    t_ok "gh received BROWSER=echo (URL-print mode)"
else
    t_fail "gh saw BROWSER='$(cat "$sb/browser_seen" 2>/dev/null || echo MISSING)' - local browser would launch"
fi
if grep -q "open it on any device" "$sb/out.txt"; then
    t_ok "operator told to use any device"
else
    t_fail "missing the any-device instruction"
fi
rm -rf "$sb"

echo "5. operator BROWSER override is respected"
sb="$(sandbox)"
run_bootstrap "$sb" RSO_GIT_REF=0.4.7 STUB_GH_AUTH_STATUS=1 BROWSER=mybrowser
if [[ "$(cat "$sb/browser_seen" 2>/dev/null)" == "mybrowser" ]]; then
    t_ok "explicit BROWSER passed through"
else
    t_fail "override lost: '$(cat "$sb/browser_seen" 2>/dev/null)'"
fi
rm -rf "$sb"

echo
echo "== $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
