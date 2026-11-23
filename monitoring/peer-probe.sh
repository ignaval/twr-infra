#!/bin/sh
# peer-probe.sh: probe the other regions' relays end to end; alert after N failures in a row.
#
# Run every minute by twr-relay-peer-probe.timer. Settings come from /etc/twr-relay/monitor.env
# (written by monitoring/install.sh, read by the unit as EnvironmentFile):
#   REGION                    this Droplet's region, for the alert text
#   PEERS                     the other regions, space-separated (for example "us")
#   RELAY_DOMAIN              default relay.twr.tools
#   PROBE_FAILS_BEFORE_ALERT  default 3
#   PROBE_TIMEOUT             seconds per probe, default 20

set -eu

lib=$(cd "$(dirname "$0")" && pwd)
state=${STATE_DIRECTORY:-/var/lib/twr-relay-monitor}
domain=${RELAY_DOMAIN:-relay.twr.tools}
threshold=${PROBE_FAILS_BEFORE_ALERT:-3}
timeout=${PROBE_TIMEOUT:-20}
twr=${TWR_BIN:-/usr/local/bin/twr}
region=${REGION:-unknown}

if [ -z "${PEERS:-}" ]; then
    echo "peer-probe: no PEERS in monitor.env; nothing to probe" >&2
    exit 0
fi
mkdir -p "$state"

# failed_checks FILE: the names and errors of the failed checks in a probe's JSON output.
failed_checks() {
    python3 -I -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        r = json.load(f)
    bad = [c for c in r.get("checks", []) if not c.get("ok")]
    print("; ".join("%s: %s" % (c.get("name"), c.get("error") or "failed") for c in bad) or "no failed check reported")
except Exception as e:
    print("unreadable probe output (%s)" % e.__class__.__name__)
' "$1" 2> /dev/null | cut -c 1-400
}

status=0
for peer in $PEERS; do
    case "$peer" in
        "" | *[!a-z0-9]*) echo "peer-probe: bad peer name $peer" >&2; status=1; continue ;;
    esac
    url="relay://$peer.$domain"
    out="$state/peer-$peer.json"
    count_file="$state/peer-$peer.fails"
    # --state: the same probe keys every minute, so the peer sees one hub and one admitted
    # pair, within its per-address limits (twr's docs/relay.md, Monitoring).
    if "$twr" relay probe "$url" --json --timeout "$timeout" --state "$state/probe-keys-$peer" > "$out" 2> "$state/peer-$peer.err"; then
        rm -f "$count_file"
        "$lib/alert.sh" "peer-$peer" ok "$region: the relay at $url answers the probe again" || true
        continue
    fi
    n=$(cat "$count_file" 2> /dev/null || echo 0)
    case "$n" in "" | *[!0-9]*) n=0 ;; esac
    n=$((n + 1))
    echo "$n" > "$count_file"
    why=$(failed_checks "$out")
    echo "peer-probe: $url failed ($n in a row): $why" >&2
    if [ "$n" -ge "$threshold" ]; then
        "$lib/alert.sh" "peer-$peer" fail \
            "$region: the probe of $url failed $n times in a row: $why" || true
    fi
done
exit "$status"
