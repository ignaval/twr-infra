#!/bin/sh
# check.sh: every offline check of this repository. Contacts nothing.
#
#   (shellcheck) all shell scripts
#   (actionlint) the workflows (and, with shellcheck on PATH, their run: scripts)
#   (files)      scripts/check-files.py: TOML configs against the relay's schema, YAML of the
#                workflows, the rendered cloud-init template, known_hosts, no secrets
#   (tests)      the installer's and alert.sh's offline tests
#   (tofu fmt)   only where tofu is installed
#
# A missing optional tool is reported as SKIPPED; with CHECK_STRICT=1 (CI) it fails instead.
# ACTIONLINT and SHELLCHECK may name the binaries. Exit status 1 if anything failed.

set -u
cd "$(dirname "$0")/.." || exit 1

failed=""
skipped=""
strict=${CHECK_STRICT:-}

run() {
    name=$1
    shift
    echo "== $name"
    if "$@"; then
        echo "-- $name: ok"
    else
        echo "-- $name: FAILED"
        failed="$failed $name"
    fi
}

skip() {
    if [ -n "$strict" ]; then
        echo "== $1: FAILED (CHECK_STRICT=1, and $2)"
        failed="$failed $1"
    else
        echo "== $1: SKIPPED ($2)"
        skipped="$skipped $1"
    fi
}

find_tool() {
    if [ -n "$2" ]; then
        printf '%s\n' "$2"
    elif command -v "$1" > /dev/null 2>&1; then
        command -v "$1"
    elif [ -x "$HOME/.local/bin/$1" ]; then
        printf '%s\n' "$HOME/.local/bin/$1"
    fi
}

scripts=$(find scripts monitoring -name '*.sh' -type f | sort)

shellcheck=$(find_tool shellcheck "${SHELLCHECK:-}")
if [ -n "$shellcheck" ]; then
    # shellcheck disable=SC2086 # one word per script path (no spaces in them)
    run shellcheck "$shellcheck" $scripts
else
    echo "== shellcheck: FAILED (shellcheck is not installed)"
    failed="$failed shellcheck"
fi

actionlint=$(find_tool actionlint "${ACTIONLINT:-}")
if [ -n "$actionlint" ]; then
    if [ -n "$shellcheck" ]; then
        run actionlint "$actionlint" -shellcheck "$shellcheck"
    else
        run actionlint "$actionlint"
    fi
else
    skip actionlint "actionlint is not installed"
fi

if command -v python3 > /dev/null 2>&1; then
    run files python3 -I scripts/check-files.py
else
    echo "== files: FAILED (python3 is not installed)"
    failed="$failed files"
fi

run test-install-twr-release sh scripts/test-install-twr-release.sh
run test-alert sh monitoring/test-alert.sh

if command -v tofu > /dev/null 2>&1; then
    run tofu-fmt tofu fmt -check -recursive -diff tofu
else
    echo "== tofu-fmt: SKIPPED (tofu is not installed; plan.yml runs it)"
    skipped="$skipped tofu-fmt"
fi

echo
if [ -n "$failed" ]; then
    echo "check.sh: FAILED:$failed${skipped:+ (skipped:$skipped)}"
    exit 1
fi
echo "check.sh: all checks passed${skipped:+ (skipped:$skipped)}"
