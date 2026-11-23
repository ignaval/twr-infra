#!/bin/sh
# test-alert.sh: offline tests of alert.sh's state, rate limit and env file parsing. A stub
# curl on PATH records what would have been sent; nothing leaves the machine.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/twr-alert-test.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$work/bin"
cat > "$work/bin/curl" << 'EOF'
#!/bin/sh
# Stub: record the config file and body; fail when STUB_CURL_FAIL is set.
conf="" body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -K) conf=$2; shift 2 ;;
        --data-binary) body=${2#@}; shift 2 ;;
        *) shift ;;
    esac
done
[ -z "${STUB_CURL_FAIL:-}" ] || exit 22
{ cat "$conf"; cat "$body"; echo "--"; } >> "$STUB_CURL_LOG"
EOF
chmod 0755 "$work/bin/curl"

export PATH="$work/bin:$PATH"
export STUB_CURL_LOG="$work/sent.log"
export ALERT_STATE_DIR="$work/state"
export ALERT_ENV_FILE="$work/alert.env"
export ALERT_LABEL=test-eu
: > "$STUB_CURL_LOG"

fails=0
expect() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: expected $2, got $3"
        fails=$((fails + 1))
    fi
}
sent() {
    grep -c '^--$' "$STUB_CURL_LOG" || true
}
alert() {
    sh "$here/alert.sh" "$@" 2> /dev/null && echo 0 || echo $?
}

# No route configured: nothing sent, nothing recorded, failure.
: > "$ALERT_ENV_FILE"
expect "no route fails" 1 "$(alert disk fail 'disk full')"
expect "no route records nothing" no "$([ -e "$ALERT_STATE_DIR/disk.open" ] && echo yes || echo no)"

# The placeholder counts as unset.
printf 'ALERT_WEBHOOK_URL=REPLACE_ME\n' > "$ALERT_ENV_FILE"
expect "placeholder is no route" 1 "$(alert disk fail 'disk full')"

# A route: one alert per outage, one recovery.
printf '# comment\nALERT_WEBHOOK_URL="https://ntfy.example/topic"\nIGNORED=1\n' > "$ALERT_ENV_FILE"
expect "first fail sends" 0 "$(alert peer-us fail 'probe failed')"
expect "second fail is quiet" 0 "$(alert peer-us fail 'probe failed')"
expect "one message so far" 1 "$(sent)"
expect "url from the env file" 1 "$(grep -c '^url = "https://ntfy.example/topic"$' "$STUB_CURL_LOG")"
expect "ok sends a recovery" 0 "$(alert peer-us ok 'back')"
expect "second ok is quiet" 0 "$(alert peer-us ok 'back')"
expect "two messages" 2 "$(sent)"
expect "recovery title" 1 "$(grep -c 'Title: twr relay test-eu: recovered' "$STUB_CURL_LOG")"

# A failed send records nothing, so the next run tries again.
expect "failed send fails" 1 "$(STUB_CURL_FAIL=1 alert cert fail "expires soon")"
expect "failed send not recorded" no "$([ -e "$ALERT_STATE_DIR/cert.open" ] && echo yes || echo no)"
expect "retry sends" 0 "$(alert cert fail 'expires soon')"

# Values that would break out of the curl config are refused.
printf 'ALERT_WEBHOOK_URL=https://ntfy.example/a"b\n' > "$ALERT_ENV_FILE"
expect "quote refused" 1 "$(alert --now fail 'x')"
printf 'ALERT_WEBHOOK_URL=http://ntfy.example/topic\n' > "$ALERT_ENV_FILE"
expect "plain http refused" 1 "$(alert --now fail 'x')"

# The hourly cap.
printf 'ALERT_WEBHOOK_URL=https://ntfy.example/topic\nALERT_MAX_PER_HOUR=4\n' > "$ALERT_ENV_FILE"
before=$(sent)
alert --now fail one > /dev/null
alert --now fail two > /dev/null
expect "cap reached" 1 "$(alert --now fail three)"
expect "cap: nothing more sent" $((before + 1)) "$(sent)"

# Bad usage.
expect "bad key" 64 "$(alert 'Bad Key' fail x)"
expect "bad state" 64 "$(alert disk maybe x)"

if [ "$fails" -ne 0 ]; then
    echo "$fails test(s) failed"
    exit 1
fi
echo "all alert.sh tests passed"
