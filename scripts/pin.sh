#!/usr/bin/env bash
# Pin install.sh and README.md's long line to a commit of this repository.
#
#   scripts/pin.sh <commit>   write <commit> and bootstrap.sh's SHA-256 at that
#                             commit into install.sh and into every pinned URL
#                             and checksum of README.md
#   scripts/pin.sh --check    check that install.sh and README.md pin the same
#                             commit, and that their SHA-256 is bootstrap.sh's
#                             there (exit 2 when that commit is not in this
#                             clone, as in a shallow one)
#
# Releasing the bootstrap: merge the change into main, then on a new branch from
# main run  scripts/pin.sh <the merged commit>  and open a pull request titled
# "release: pin <short sha>". A commit cannot contain its own hash, so the pin
# always follows the code in a small pull request of its own.
#
# PIN_README=<file> and PIN_INSTALL=<file> point both modes at other copies (the
# tests use them).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${PIN_README:-$ROOT/README.md}"
INSTALL="${PIN_INSTALL:-$ROOT/install.sh}"
URL_RE='morebees-installer/[0-9a-f]{40}/bootstrap\.sh'
SUM_RE='echo "[0-9a-f]{64}  '
INSTALL_COMMIT_RE='^MB_PIN_COMMIT="[0-9a-f]{40}"$'
INSTALL_SUM_RE='^MB_PIN_SHA256="[0-9a-f]{64}"$'

die() { echo "pin.sh: $*" >&2; exit 1; }

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# The README's pin: every URL must name one commit and every check one checksum.
read_pin() {
    local commits sums
    commits="$(grep -oE "$URL_RE" "$README" | cut -d/ -f2 | sort -u)"
    sums="$(grep -oE "$SUM_RE" "$README" | cut -c7-70 | sort -u)"
    [[ -n "$commits" && -n "$sums" ]] || die "$README has no pinned one-liner to read"
    [[ "$(printf '%s\n' "$commits" | wc -l | tr -d ' ')" == 1 ]] \
        || die "$README names more than one commit: $(echo "$commits" | tr '\n' ' ')"
    [[ "$(printf '%s\n' "$sums" | wc -l | tr -d ' ')" == 1 ]] \
        || die "$README carries more than one checksum: $(echo "$sums" | tr '\n' ' ')"
    PIN_COMMIT="$commits"
    PIN_SUM="$sums"
}

# install.sh's pin: one MB_PIN_COMMIT line and one MB_PIN_SHA256 line.
read_install_pin() {
    local commits sums
    commits="$(grep -E "$INSTALL_COMMIT_RE" "$INSTALL" | cut -d'"' -f2)" || commits=""
    sums="$(grep -E "$INSTALL_SUM_RE" "$INSTALL" | cut -d'"' -f2)" || sums=""
    [[ -n "$commits" && -n "$sums" ]] || die "$INSTALL has no pin to read"
    [[ "$(printf '%s\n' "$commits" | wc -l | tr -d ' ')" == 1 && "$(printf '%s\n' "$sums" | wc -l | tr -d ' ')" == 1 ]] \
        || die "$INSTALL carries more than one pin"
    INSTALL_COMMIT="$commits"
    INSTALL_SUM="$sums"
}

sum_at() {  # sum_at <commit>: SHA-256 of bootstrap.sh at <commit>
    git -C "$ROOT" show "$1:bootstrap.sh" | sha256_stdin
}

check() {
    read_pin
    read_install_pin
    if [[ "$INSTALL_COMMIT" != "$PIN_COMMIT" || "$INSTALL_SUM" != "$PIN_SUM" ]]; then
        die "$INSTALL pins $INSTALL_COMMIT ($INSTALL_SUM), but $README pins $PIN_COMMIT ($PIN_SUM)"
    fi
    if ! git -C "$ROOT" cat-file -e "$PIN_COMMIT^{commit}" 2>/dev/null; then
        echo "pin.sh: commit $PIN_COMMIT is not in this clone; cannot check the pin." >&2
        exit 2
    fi
    local want
    want="$(sum_at "$PIN_COMMIT")"
    if [[ "$want" != "$PIN_SUM" ]]; then
        die "$README pins $PIN_COMMIT with SHA-256 $PIN_SUM, but bootstrap.sh there has $want"
    fi
    echo "install.sh and README pin OK: $PIN_COMMIT, bootstrap.sh SHA-256 $PIN_SUM"
}

pin() {
    local commit sum tmp
    commit="$(git -C "$ROOT" rev-parse --verify --quiet "$1^{commit}")" \
        || die "not a commit in this repository: $1"
    git -C "$ROOT" cat-file -e "$commit:bootstrap.sh" 2>/dev/null \
        || die "commit $commit has no bootstrap.sh"
    sum="$(sum_at "$commit")"
    read_pin
    read_install_pin
    tmp="$(mktemp "$README.XXXXXX")"
    sed -e "s/$PIN_COMMIT/$commit/g" -e "s/$PIN_SUM/$sum/g" "$README" > "$tmp"
    cat "$tmp" > "$README"   # keeps the file's own mode
    # install.sh's two lines are rewritten by their names, so a pin that once
    # went out of step with the README's is put right too.
    sed -E -e "s/^MB_PIN_COMMIT=\"[0-9a-f]{40}\"\$/MB_PIN_COMMIT=\"$commit\"/" \
        -e "s/^MB_PIN_SHA256=\"[0-9a-f]{64}\"\$/MB_PIN_SHA256=\"$sum\"/" "$INSTALL" > "$tmp"
    cat "$tmp" > "$INSTALL"
    rm -f "$tmp"
    read_pin
    read_install_pin
    [[ "$PIN_COMMIT" == "$commit" && "$PIN_SUM" == "$sum" && "$INSTALL_COMMIT" == "$commit" && "$INSTALL_SUM" == "$sum" ]] \
        || die "the rewrite did not take"
    echo "install.sh and README pinned to $commit (bootstrap.sh SHA-256 $sum)."
    echo "Commit it as:  release: pin ${commit:0:7}"
}

case "${1:-}" in
    --check) check ;;
    ""|-h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) pin "$1" ;;
esac
