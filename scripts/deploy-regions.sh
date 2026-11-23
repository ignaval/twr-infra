#!/bin/sh
# deploy-regions.sh: the runner half of a deploy (.github/workflows/deploy.yml). One region at
# a time: upload the bundle over SSH, run apply-release.sh there, then probe the region from
# here with `twr relay probe`. A failure stops before the next region.
#
# usage: deploy-regions.sh --tag TAG --regions eu,us --release-dir DIR --twr PATH
#
#   --release-dir  the release files install-twr-release.sh checked (its --keep-dir)
#   --twr          a twr binary for `twr relay probe` (the same release)
#
# Environment:
#   DEPLOY_SSH_KEY_FILE  the deploy user's private key (required)
#   KNOWN_HOSTS          pinned host keys (default: known_hosts at the repository root);
#                        entries are keyed by HostKeyAlias twr-relay-<region>
#   RELAY_DOMAIN         default relay.twr.tools
#   PROBE_ATTEMPTS       default 6; PROBE_INTERVAL default 20 (seconds between attempts)
#   ALERT_WEBHOOK_URL, ALERT_WEBHOOK_TOKEN, ALERT_SMTP_URL, ALERT_SMTP_USER,
#   ALERT_SMTP_PASSWORD, ALERT_EMAIL_FROM, ALERT_EMAIL_TO
#                        if any is set, they become /etc/twr-relay/alert.env on each Droplet;
#                        if none is, each Droplet keeps the alert.env it has

set -eu
umask 077

say() {
    printf 'deploy: %s\n' "$*" >&2
}
err() {
    printf 'deploy: error: %s\n' "$*" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error::%s\n' "$*"
    fi
    exit 1
}

repo=$(cd "$(dirname "$0")/.." && pwd)
tag=""
regions=""
release_dir=""
twr=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) [ $# -ge 2 ] || err "--tag needs a value"; tag=$2; shift 2 ;;
        --regions) [ $# -ge 2 ] || err "--regions needs a value"; regions=$2; shift 2 ;;
        --release-dir) [ $# -ge 2 ] || err "--release-dir needs a value"; release_dir=$2; shift 2 ;;
        --twr) [ $# -ge 2 ] || err "--twr needs a value"; twr=$2; shift 2 ;;
        *) err "unknown argument: $1" ;;
    esac
done

case "$tag" in
    v[0-9]*) ;;
    *) err "--tag $tag is not a release tag" ;;
esac
case "$tag" in
    *[!A-Za-z0-9.+-]*) err "--tag $tag has characters a release tag doesn't" ;;
esac
[ -d "$release_dir" ] || err "--release-dir $release_dir is not a directory"
[ -x "$twr" ] || err "--twr $twr is not an executable"
key=${DEPLOY_SSH_KEY_FILE:-}
[ -n "$key" ] && [ -f "$key" ] || err "DEPLOY_SSH_KEY_FILE does not name the deploy key"
known_hosts=${KNOWN_HOSTS:-$repo/known_hosts}
[ -f "$known_hosts" ] || err "no known_hosts at $known_hosts"
domain=${RELAY_DOMAIN:-relay.twr.tools}
case "$domain" in
    "" | *[!a-z0-9.-]*) err "bad RELAY_DOMAIN $domain" ;;
esac
attempts=${PROBE_ATTEMPTS:-6}
interval=${PROBE_INTERVAL:-20}

# Every region this repository knows (config/<region>.toml): each Droplet probes the others.
all_regions=""
for f in "$repo"/config/*.toml; do
    r=$(basename "$f" .toml)
    all_regions="$all_regions $r"
done

# Check every requested region before touching the first one.
order=$(printf '%s' "$regions" | tr ',' ' ')
[ -n "$(printf '%s' "$order" | tr -d ' ')" ] || err "--regions is empty"
seen=" "
for r in $order; do
    case "$r" in
        *[!a-z0-9]*) err "bad region name: $r" ;;
    esac
    case "$seen" in
        *" $r "*) err "region $r is listed twice" ;;
    esac
    seen="$seen$r "
    [ -f "$repo/config/$r.toml" ] || err "no config/$r.toml for region $r"
    # A pinned host key, never trust on first use.
    awk -v a="twr-relay-$r" '$1 == a || index($1, a ",") == 1 { found = 1 } END { exit !found }' \
        "$known_hosts" || err "known_hosts has no host key for twr-relay-$r (docs/runbook.md, Host keys)"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/twr-deploy.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

nl=$(printf '\nx')
nl=${nl%x}
alert_env=""
for v in ALERT_WEBHOOK_URL ALERT_WEBHOOK_TOKEN ALERT_SMTP_URL ALERT_SMTP_USER \
    ALERT_SMTP_PASSWORD ALERT_EMAIL_FROM ALERT_EMAIL_TO; do
    eval "val=\${$v:-}"
    # shellcheck disable=SC2154 # val is set by the eval above
    if [ -n "$val" ]; then
        case "$val" in *"$nl"*) err "$v holds a newline" ;; esac
        printf '%s=%s\n' "$v" "$val" >> "$work/alert.env"
        alert_env=1
    fi
done

summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# print_probe FILE: one line per check of `twr relay probe --json`.
print_probe() {
    python3 -I -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        r = json.load(f)
except Exception as e:
    print("    (no JSON from the probe: %s)" % e.__class__.__name__)
    sys.exit(0)
print("    ok: %s" % r.get("ok"))
for c in r.get("checks", []):
    line = "    %-4s %s" % ("ok" if c.get("ok") else "FAIL", c.get("name"))
    if c.get("ms") is not None:
        line += " (%s ms)" % c.get("ms")
    if c.get("error"):
        line += ": %s" % c.get("error")
    print(line)
' "$1"
}

summary "## Deploy $tag"
summary ""
for r in $order; do
    host="$r.$domain"
    peers=""
    for p in $all_regions; do
        if [ "$p" != "$r" ]; then peers="${peers:+$peers }$p"; fi
    done

    say "=== $r ($host): uploading and applying $tag"
    b="$work/bundle-$r"
    mkdir -p "$b/release" "$b/monitoring/systemd"
    cp "$repo/scripts/install-twr-release.sh" "$repo/scripts/apply-release.sh" "$b/"
    cp "$repo/keys/twr-release-signing-key.pub" "$b/"
    cp "$release_dir"/* "$b/release/"
    cp "$repo/config/$r.toml" "$b/relay.toml"
    cp "$repo"/monitoring/*.sh "$repo/monitoring/alert.env.example" "$b/monitoring/"
    cp "$repo"/monitoring/systemd/* "$b/monitoring/systemd/"
    if [ -n "$alert_env" ]; then
        cp "$work/alert.env" "$b/alert.env"
    fi

    # The values in the remote command were all checked above to be [A-Za-z0-9.+-] or spaces.
    remote="set -eu; d=\$(mktemp -d /tmp/twr-deploy.XXXXXXXX); trap 'rm -rf \"\$d\"' EXIT;"
    remote="$remote tar -xzf - -C \"\$d\";"
    remote="$remote sudo -n sh \"\$d/apply-release.sh\" --tag '$tag' --region '$r' --bundle \"\$d\" --peers '$peers' --domain '$domain'"
    if ! tar -C "$b" -czf - . | ssh -4 -T \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o IdentityFile="$key" \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$known_hosts" \
        -o GlobalKnownHostsFile=/dev/null \
        -o HostKeyAlias="twr-relay-$r" \
        -o UpdateHostKeys=no \
        -o ConnectTimeout=20 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=4 \
        "deploy@$host" "$remote"; then
        summary "- **$r**: apply failed; the remaining regions were not touched"
        err "applying $tag on $r failed; not deploying the remaining regions"
    fi
    rm -rf "$b"

    say "=== $r: probing relay://$host"
    n=1
    ok=""
    while [ "$n" -le "$attempts" ]; do
        if "$twr" relay probe "relay://$host" --json --timeout 30 > "$work/probe-$r.json" 2> "$work/probe-$r.err"; then
            ok=1
            break
        fi
        say "probe $n of $attempts failed:"
        print_probe "$work/probe-$r.json" >&2
        sed 's/^/    /' "$work/probe-$r.err" | tail -n 5 >&2
        n=$((n + 1))
        if [ "$n" -le "$attempts" ]; then sleep "$interval"; fi
    done
    print_probe "$work/probe-$r.json" >&2
    if [ -z "$ok" ]; then
        summary "- **$r**: $tag applied, but the probe failed $attempts times; the remaining regions were not touched"
        err "the probe of $r failed after $tag was applied; not deploying the remaining regions (roll back: docs/runbook.md)"
    fi
    summary "- **$r**: $tag applied, probe passed"
    say "=== $r: done"
done
say "deployed $tag to: $order"
