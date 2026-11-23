#!/bin/sh
# local-check.sh: this Droplet's own health, every 5 minutes (twr-relay-local-check.timer).
#
# Each condition has its own alert key, so each sends one alert and one recovery:
#   service  twr-relay.service is not active
#   metrics  the service is active but http://127.0.0.1:9469/metrics doesn't answer
#   cert     the relay's certificate expires in under CERT_MIN_DAYS (default 14) days, or it
#            has had none (twr_relay_cert_expiry_seconds = -1) for over an hour of uptime
#   disk     / or the relay's state directory is over DISK_MAX_PERCENT (default 85) full
#   reboot   a reboot has been pending (/var/run/reboot-required) for over REBOOT_MAX_DAYS
#            (default 3) days: the automatic reboot didn't happen
# Settings from /etc/twr-relay/monitor.env (REGION; the thresholds above, all optional).

set -eu

lib=$(cd "$(dirname "$0")" && pwd)
region=${REGION:-unknown}
metrics_url=${METRICS_URL:-http://127.0.0.1:9469/metrics}
cert_min_days=${CERT_MIN_DAYS:-14}
disk_max=${DISK_MAX_PERCENT:-85}
reboot_max_days=${REBOOT_MAX_DAYS:-3}
alert="$lib/alert.sh"

check() {
    "$alert" "$1" "$2" "$region: $3" || true
}

# service
if systemctl is-active --quiet twr-relay.service; then
    check service ok "twr-relay.service is active again"
    active=1
else
    check service fail "twr-relay.service is $(systemctl is-active twr-relay.service 2> /dev/null || true)"
    active=""
fi

# metrics and cert (only meaningful while the service runs)
if [ -n "$active" ]; then
    if metrics=$(curl -fsS --max-time 5 "$metrics_url" 2> /dev/null); then
        check metrics ok "the metrics endpoint answers again"
        expiry=$(printf '%s\n' "$metrics" | awk '$1 == "twr_relay_cert_expiry_seconds" { print $2; exit }')
        since=$(systemctl show -p ActiveEnterTimestamp --value twr-relay.service 2> /dev/null || true)
        since_s=$(date -d "$since" +%s 2> /dev/null || echo 0)
        up_s=$(($(date +%s) - since_s))
        verdict=$(awk -v e="${expiry:-missing}" -v min=$((cert_min_days * 86400)) -v up="$up_s" 'BEGIN {
            if (e == "missing") { print "missing"; exit }
            if (e + 0 < 0) { print (up > 3600 ? "none" : "starting"); exit }
            print (e + 0 < min ? "soon" : "ok")
        }')
        case "$verdict" in
            ok) check cert ok "the relay's certificate is valid for $(awk -v e="$expiry" 'BEGIN { printf "%d", e / 86400 }') more days" ;;
            soon) check cert fail "the relay's certificate expires in $(awk -v e="$expiry" 'BEGIN { printf "%.1f", e / 86400 }') days (renewal is automatic; see docs/runbook.md, Certificates)" ;;
            none) check cert fail "the relay has had no certificate for over an hour (ACME failing? DNS, CAA, port 443; see docs/runbook.md)" ;;
            missing) check cert fail "the metrics have no twr_relay_cert_expiry_seconds" ;;
            starting) ;;
        esac
    else
        check metrics fail "twr-relay.service is active but $metrics_url does not answer"
    fi
fi

# disk
used=$(df -P / /var/lib/twr-relay 2> /dev/null | awk 'NR > 1 { gsub("%", "", $5); if ($5 + 0 > m) m = $5 + 0 } END { print m + 0 }')
if [ "$used" -gt "$disk_max" ]; then
    check disk fail "a disk is ${used}% full (threshold ${disk_max}%)"
else
    check disk ok "disk use is back to ${used}%"
fi

# reboot
if [ -e /var/run/reboot-required ] &&
    [ -n "$(find /var/run/reboot-required -mmin +$((reboot_max_days * 1440)) 2> /dev/null)" ]; then
    check reboot fail "a reboot has been pending for over $reboot_max_days days ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2> /dev/null | cut -c 1-200))"
else
    check reboot ok "no reboot is overdue"
fi
