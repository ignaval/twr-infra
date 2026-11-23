#!/bin/sh
# apply-release.sh: the on-Droplet half of a deploy, run as root by scripts/deploy-regions.sh
# (through sudo, from the bundle it uploads).
#
# usage: apply-release.sh --tag TAG --region REGION --bundle DIR [--peers "us ..."]
#                         [--domain relay.twr.tools]
#
# The bundle holds install-twr-release.sh, twr-release-signing-key.pub, release/ (the files
# the runner already checked; checked again here), relay.toml, monitoring/ and, optionally,
# alert.env. Steps:
#   1. keep the installer and the key in /usr/local/share/twr-infra/;
#   2. keep the current twr and relay.toml as twr.prev and relay.toml.prev;
#   3. install twr (install-twr-release.sh, fail closed) and this region's relay.toml;
#   4. install the systemd unit with `twr relay serve --install --no-start` if it is missing;
#   5. install monitoring, and alert.env if the bundle has one;
#   6. restart twr-relay and wait for it to stay active. If it doesn't, put twr.prev and
#      relay.toml.prev back, restart, and fail, so that the deploy stops.

set -eu
umask 022

say() {
    printf 'apply-release: %s\n' "$*" >&2
}
err() {
    printf 'apply-release: error: %s\n' "$*" >&2
    exit 1
}

tag=""
region=""
bundle=""
peers=""
domain=relay.twr.tools
acme_contact=mailto:relay-ops@twr.tools
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) [ $# -ge 2 ] || err "--tag needs a value"; tag=$2; shift 2 ;;
        --region) [ $# -ge 2 ] || err "--region needs a value"; region=$2; shift 2 ;;
        --bundle) [ $# -ge 2 ] || err "--bundle needs a value"; bundle=$2; shift 2 ;;
        --peers) [ $# -ge 2 ] || err "--peers needs a value"; peers=$2; shift 2 ;;
        --domain) [ $# -ge 2 ] || err "--domain needs a value"; domain=$2; shift 2 ;;
        *) err "unknown argument: $1" ;;
    esac
done
case "$region" in
    "" | *[!a-z0-9]*) err "--region is a lowercase region name" ;;
esac
[ -n "$tag" ] || err "--tag is required"
[ -d "$bundle" ] || err "--bundle $bundle is not a directory"
[ "$(id -u)" = 0 ] || err "run as root"

share=/usr/local/share/twr-infra
bin=/usr/local/bin/twr
conf=/etc/twr-relay/relay.toml
unit=/etc/systemd/system/twr-relay.service

# 1.
install -d -m 0755 "$share" /etc/twr-relay
install -m 0755 "$bundle/install-twr-release.sh" "$share/install-twr-release.sh"
install -m 0644 "$bundle/twr-release-signing-key.pub" "$share/twr-release-signing-key.pub"

# 2.
had_prev=""
if [ -f "$bin" ]; then
    cp -p "$bin" "$bin.prev"
    had_prev=1
fi
if [ -f "$conf" ]; then
    cp -p "$conf" "$conf.prev"
fi

# 3.
sh "$share/install-twr-release.sh" --tag "$tag" --key "$share/twr-release-signing-key.pub" \
    --from-dir "$bundle/release" --dest /usr/local/bin
install -m 0644 "$bundle/relay.toml" "$conf.new"
mv -f "$conf.new" "$conf"

# 4. `--install` keeps an existing relay.toml, so the file above is the one it uses.
if [ ! -f "$unit" ]; then
    say "no $unit yet: installing the service"
    "$bin" relay serve --install --hostname "$region.$domain" --region "$region" \
        --acme-contact "$acme_contact" --no-start
fi

# 5.
sh "$bundle/monitoring/install.sh" --region "$region" --peers "$peers" --domain "$domain"
if [ -f "$bundle/alert.env" ]; then
    (umask 077 && cp "$bundle/alert.env" /etc/twr-relay/alert.env.new)
    chown root:root /etc/twr-relay/alert.env.new
    chmod 0600 /etc/twr-relay/alert.env.new
    mv -f /etc/twr-relay/alert.env.new /etc/twr-relay/alert.env
    rm -f "$bundle/alert.env"
    say "updated /etc/twr-relay/alert.env"
fi

# 6. Active now, and still active a few seconds later (not crash-looping).
stays_active() {
    i=0
    while [ "$i" -lt 20 ]; do
        if systemctl is-active --quiet twr-relay.service; then
            sleep 5
            systemctl is-active --quiet twr-relay.service && return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

systemctl daemon-reload
systemctl enable twr-relay.service > /dev/null 2>&1 || true
systemctl restart twr-relay.service || true
if stays_active; then
    say "twr-relay is active with $("$bin" --version 2> /dev/null || echo "an unknown version")"
    if curl -fsS --max-time 5 http://127.0.0.1:9469/metrics 2> /dev/null | grep -q '^twr_relay_up 1'; then
        say "metrics: twr_relay_up 1"
    else
        say "warning: http://127.0.0.1:9469/metrics does not show twr_relay_up 1 (yet)"
    fi
    exit 0
fi

say "twr-relay did not stay active; last log lines:"
journalctl -u twr-relay.service -n 30 --no-pager >&2 || true
if [ -n "$had_prev" ]; then
    say "rolling back to the previous twr and relay.toml"
    mv -f "$bin.prev" "$bin"
    if [ -f "$conf.prev" ]; then
        mv -f "$conf.prev" "$conf"
    fi
    systemctl restart twr-relay.service || true
    if stays_active; then
        say "the previous version is active again"
    else
        say "the previous version did not come back either"
    fi
fi
err "deploy of $tag to $region failed: the relay did not stay active"
