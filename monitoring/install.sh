#!/bin/sh
# monitoring/install.sh: install or update this repository's monitoring on a relay Droplet.
# Run as root by scripts/apply-release.sh on every deploy; safe to run again.
#
# usage: install.sh --region REGION [--peers "us ..."] [--domain relay.twr.tools]
#
# Installs the scripts into /usr/local/lib/twr-relay-monitor/, the units into
# /etc/systemd/system/, writes /etc/twr-relay/monitor.env (not secret) and, if missing, a
# placeholder /etc/twr-relay/alert.env (0600), then enables both timers.

set -eu

say() {
    printf 'monitoring/install: %s\n' "$*" >&2
}
err() {
    printf 'monitoring/install: error: %s\n' "$*" >&2
    exit 1
}

region=""
peers=""
domain=relay.twr.tools
while [ $# -gt 0 ]; do
    case "$1" in
        --region) [ $# -ge 2 ] || err "--region needs a value"; region=$2; shift 2 ;;
        --peers) [ $# -ge 2 ] || err "--peers needs a value"; peers=$2; shift 2 ;;
        --domain) [ $# -ge 2 ] || err "--domain needs a value"; domain=$2; shift 2 ;;
        *) err "unknown argument: $1" ;;
    esac
done
case "$region" in
    "" | *[!a-z0-9]*) err "--region is a lowercase region name" ;;
esac
for p in $peers; do
    case "$p" in *[!a-z0-9]*) err "bad peer region name: $p" ;; esac
done
case "$domain" in
    "" | *[!a-z0-9.-]*) err "bad --domain $domain" ;;
esac
[ "$(id -u)" = 0 ] || err "run as root"

src=$(cd "$(dirname "$0")" && pwd)
lib=/usr/local/lib/twr-relay-monitor

install -d -m 0755 "$lib" /etc/twr-relay
for f in alert.sh peer-probe.sh local-check.sh; do
    install -m 0755 "$src/$f" "$lib/$f"
done
for u in twr-relay-peer-probe.service twr-relay-peer-probe.timer \
    twr-relay-local-check.service twr-relay-local-check.timer; do
    install -m 0644 "$src/systemd/$u" "/etc/systemd/system/$u"
done

# Not secret: region names and the domain.
{
    echo "# Written by twr-infra monitoring/install.sh; replaced on every deploy."
    echo "REGION=$region"
    echo "PEERS=$peers"
    echo "RELAY_DOMAIN=$domain"
} > /etc/twr-relay/monitor.env.new
chmod 0644 /etc/twr-relay/monitor.env.new
mv -f /etc/twr-relay/monitor.env.new /etc/twr-relay/monitor.env

if [ ! -e /etc/twr-relay/alert.env ]; then
    (umask 077 && cp "$src/alert.env.example" /etc/twr-relay/alert.env)
    say "wrote a placeholder /etc/twr-relay/alert.env: alerts are only logged until it holds a route"
fi
chown root:root /etc/twr-relay/alert.env
chmod 0600 /etc/twr-relay/alert.env

systemctl daemon-reload
systemctl enable --now twr-relay-peer-probe.timer twr-relay-local-check.timer
say "monitoring installed for region $region (peers: ${peers:-none})"
