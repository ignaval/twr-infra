#!/bin/sh
# monitor-external.sh: the outside check of .github/workflows/monitor.yml. Probes every region
# from a GitHub runner, for the case the Droplets can't report themselves: both regions down
# together (each Droplet's peer probe covers one region down).
#
# usage: monitor-external.sh --twr PATH|--no-twr REASON
#
# The previous completed run's conclusion is the state: this run fails (red) only when every
# region fails, and it alerts only on a change (success -> failure: one alert; failure ->
# success: one recovery), so a long outage sends one of each. One region down is a warning in
# the run, not an alert. Needs GH_TOKEN (actions: read) and GITHUB_REPOSITORY for `gh`, and
# the ALERT_* variables of monitoring/alert.sh.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
twr=""
broken=""
case "${1:-}" in
    --twr) twr=${2:?--twr needs a path} ;;
    --no-twr) broken=${2:-the probe could not be installed} ;;
    *) echo "usage: monitor-external.sh --twr PATH|--no-twr REASON" >&2; exit 64 ;;
esac
domain=${RELAY_DOMAIN:-relay.twr.tools}

export ALERT_ENV_FILE=/nonexistent
export ALERT_LABEL="${ALERT_LABEL:-github-monitor}"
export ALERT_STATE_DIR="${ALERT_STATE_DIR:-${RUNNER_TEMP:-/tmp}/alert-state}"

# The last finished run that succeeded or failed (not this one, which is still running).
previous=$(gh run list -R "${GITHUB_REPOSITORY:?}" --workflow monitor.yml --limit 20 \
    --json status,conclusion,databaseId \
    -q "[.[] | select(.status == \"completed\" and (.conclusion == \"success\" or .conclusion == \"failure\")) | select(.databaseId != ${GITHUB_RUN_ID:-0})][0].conclusion // \"unknown\"" \
    2> /dev/null || echo unknown)
echo "previous run: $previous"

passed=""
failed=""
if [ -z "$broken" ]; then
    for f in "$repo"/config/*.toml; do
        r=$(basename "$f" .toml)
        url="relay://$r.$domain"
        ok=""
        for attempt in 1 2; do
            if "$twr" relay probe "$url" --json --timeout 30 > "${RUNNER_TEMP:-/tmp}/probe-$r.json" 2>&1; then
                ok=1
                break
            fi
            if [ "$attempt" = 1 ]; then sleep 30; fi
        done
        if [ -n "$ok" ]; then
            echo "$url: ok"
            passed="$passed $r"
        else
            echo "$url: FAILED twice, 30 s apart"
            sed 's/^/    /' "${RUNNER_TEMP:-/tmp}/probe-$r.json" | head -c 2000
            echo
            failed="$failed $r"
        fi
    done
fi

if [ -n "$broken" ]; then
    down="the external monitor could not run: $broken"
elif [ -z "$passed" ]; then
    down="every region failed its probe from GitHub:$failed"
else
    down=""
    if [ -n "$failed" ]; then
        echo "::warning::probe failed for:$failed (the other region's Droplet alerts for this)"
    fi
fi

if [ -n "$down" ]; then
    echo "::error::$down"
    if [ "$previous" != failure ]; then
        sh "$repo/monitoring/alert.sh" --now fail "$down" ||
            echo "::error::the alert could not be sent (check the ALERT_* repository secrets)"
    fi
    exit 1
fi
if [ "$previous" = failure ]; then
    sh "$repo/monitoring/alert.sh" --now ok "the relay answers probes from GitHub again (ok:$passed)" ||
        echo "::warning::the recovery message could not be sent"
fi
echo "ok:$passed"
