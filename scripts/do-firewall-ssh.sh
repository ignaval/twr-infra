#!/bin/sh
# do-firewall-ssh.sh: open TCP 22 in the relay's DigitalOcean cloud firewall for this
# machine's public IPv4 address only, and close it again. Used by the deploy workflow,
# whose runner has a different address on every run; the firewall has no SSH rule otherwise
# (tofu variable admin_ssh_cidrs, empty by default).
#
# usage: do-firewall-ssh.sh open|close
#
# Environment:
#   DO_FIREWALL_TOKEN  a DigitalOcean API token allowed to update firewalls (required)
#   DO_FIREWALL_ID     the firewall's ID (tofu output firewall_id)
#   SSH_RULE_STATE     file remembering the opened address (default $RUNNER_TEMP/ssh-rule-ip)
#
# Uses the DigitalOcean API's "add rules to a firewall" and "remove rules from a firewall"
# (POST and DELETE /v2/firewalls/<id>/rules). A rule left behind by a failed close is removed
# by the next `tofu apply`, which owns the firewall's rules. Unverified against the live API.

set -eu
umask 077

say() {
    printf 'do-firewall-ssh: %s\n' "$*" >&2
}
err() {
    printf 'do-firewall-ssh: error: %s\n' "$*" >&2
    exit 1
}

action=${1:-}
token=${DO_FIREWALL_TOKEN:-}
fw=${DO_FIREWALL_ID:-}
state=${SSH_RULE_STATE:-${RUNNER_TEMP:-/tmp}/ssh-rule-ip}
[ -n "$token" ] || err "DO_FIREWALL_TOKEN is not set"
case "$token" in *[!A-Za-z0-9_]*) err "DO_FIREWALL_TOKEN has unexpected characters" ;; esac
case "$fw" in
    "" | *[!0-9a-f-]*) err "DO_FIREWALL_ID is not a firewall ID (tofu output firewall_id)" ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/do-fw.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

# rules METHOD IP: POST or DELETE the one inbound rule for IP/32.
rules() {
    printf '{"inbound_rules":[{"protocol":"tcp","ports":"22","sources":{"addresses":["%s/32"]}}]}' "$2" \
        > "$work/body.json"
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$work/curl.conf"
    code=$(curl -sS --proto '=https' --tlsv1.2 --max-time 30 --retry 2 -o "$work/resp" -w '%{http_code}' \
        -K "$work/curl.conf" -X "$1" -H 'Content-Type: application/json' \
        --data-binary "@$work/body.json" "https://api.digitalocean.com/v2/firewalls/$fw/rules") || code=000
    case "$code" in
        2??) return 0 ;;
    esac
    say "the DigitalOcean API answered $code: $(head -c 300 "$work/resp" 2> /dev/null || true)"
    return 1
}

case "$action" in
    open)
        ip=$(curl -fsS -4 --proto '=https' --max-time 10 https://api.ipify.org) || err "could not learn this runner's public IPv4 address"
        case "$ip" in
            *[!0-9.]* | "" | *..* | .* | *.) err "not an IPv4 address: $ip" ;;
        esac
        [ "$(printf '%s' "$ip" | tr -cd '.' | wc -c | tr -d ' ')" = 3 ] || err "not an IPv4 address: $ip"
        rules POST "$ip" || err "could not open SSH for $ip"
        printf '%s\n' "$ip" > "$state"
        say "opened TCP 22 for $ip/32"
        # The API applies rules within seconds; give it a moment before the first connection.
        sleep 10
        ;;
    close)
        if [ ! -f "$state" ]; then
            say "nothing to close"
            exit 0
        fi
        ip=$(cat "$state")
        rules DELETE "$ip" || err "could not remove the SSH rule for $ip/32; the next tofu apply removes it, or delete it in the control panel"
        rm -f "$state"
        say "closed TCP 22 for $ip/32"
        ;;
    *)
        err "usage: do-firewall-ssh.sh open|close"
        ;;
esac
