#!/usr/bin/env bash
# MoreBees installer, the short command:
#
#   curl -fsSL https://raw.githubusercontent.com/JConeLab/morebees-installer/main/install.sh | bash
#
# Options go after "bash -s --" and variables before "bash", for example
#   ... | bash -s -- --standalone --only 90
#   ... | RSO_GIT_REF=v0.5.0 bash
#
# It downloads bootstrap.sh at one fixed commit of this repository (the pin
# below, which scripts/pin.sh writes, as it writes the README's long line),
# checks its SHA-256, and runs it only when the check passes, with the options
# and the terminal; the bootstrap's exit status is this script's. This file is
# read from main each time, and main changes only through a pull request with
# green CI.
#
# Everything runs from main(), called inside braces on the last line: bash runs
# a script piped from curl as it arrives, but reads a { ... } whole before it
# runs any of it, so a download cut short, even inside that line, runs nothing
# (cut after "main " alone, it would run the bootstrap without the options).
#
# Test seam: MB_TTY, the terminal (/dev/tty), as in bootstrap.sh.
set -Eeuo pipefail

MB_PIN_COMMIT="6a034382e1749009fd15d781b45dfcb63d45379e"
MB_PIN_SHA256="1c937f12069bca11af434e3e965d27260300719a36e4b2aa7aeda33fc6057405"

MB_TMP=""

_say() { printf 'install.sh: %s\n' "$*" >&2 || true; }

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# shellcheck disable=SC2329  # run by the EXIT trap
_remove_tmp() {
    if [[ -n "$MB_TMP" ]]; then
        rm -f -- "$MB_TMP"
    fi
}

main() {
    local url sum rc=0 tty="${MB_TTY:-/dev/tty}"
    url="https://raw.githubusercontent.com/JConeLab/morebees-installer/$MB_PIN_COMMIT/bootstrap.sh"
    trap _remove_tmp EXIT
    MB_TMP="$(mktemp "${TMPDIR:-/tmp}/morebees-bootstrap.XXXXXX")" || {
        _say "could not make a temporary file; nothing was run."
        return 1
    }
    if ! curl -fsSL -o "$MB_TMP" "$url"; then
        _say "could not download bootstrap.sh at commit ${MB_PIN_COMMIT:0:7}; nothing was run."
        return 1
    fi
    sum="$(_sha256 "$MB_TMP")" || sum=""
    if [[ "$sum" != "$MB_PIN_SHA256" ]]; then
        _say "the downloaded bootstrap.sh does not match its pinned SHA-256; nothing was run."
        _say "  expected $MB_PIN_SHA256"
        _say "  got      ${sum:-nothing}"
        return 1
    fi
    # The terminal is the bootstrap's input, for its questions and the sign-in;
    # never this script's own input, which is the rest of the pipe from curl.
    if (exec <"$tty") 2>/dev/null; then
        "${BASH:-bash}" "$MB_TMP" "$@" <"$tty" || rc=$?
    else
        "${BASH:-bash}" "$MB_TMP" "$@" </dev/null || rc=$?
    fi
    return "$rc"
}

{ main "$@"; exit $?; }
