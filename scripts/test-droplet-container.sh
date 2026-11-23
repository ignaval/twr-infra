#!/bin/sh
# test-droplet-container.sh: the Droplet side of a deploy, end to end, in a local Ubuntu
# container with systemd: apply-release.sh installs a release (signed with a throwaway key,
# holding the twr binary you give), the relay's systemd unit and monitoring; then the relay is
# probed, deployed again, given a config it refuses, and given a release that crashes, which
# must roll back. Contacts nothing but Docker Hub and Ubuntu's archive (for the image).
#
#   sh scripts/test-droplet-container.sh /path/to/twr [ubuntu image, default ubuntu:26.04]
#
# The twr must have `twr relay` and run on that image (a glibc build from a recent Ubuntu, or
# the static musl release). The config is config/eu.toml with `tls.mode = "self-signed"`,
# because the container can't get a Let's Encrypt certificate; everything else is as deployed.
# Needs Docker with --privileged (systemd as PID 1).
# shellcheck disable=SC2015 # `cond && pass || bad`: pass always succeeds
set -eu
cd "$(dirname "$0")/.."

twr=${1:?usage: test-droplet-container.sh /path/to/twr [image]}
image=${2:-ubuntu:26.04}
[ -x "$twr" ] || { echo "no executable twr at $twr" >&2; exit 2; }
"$twr" relay --help > /dev/null 2>&1 || { echo "$twr has no 'twr relay'" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/twr-droplet-test.XXXXXXXX")
name=twr-droplet-test-$$
tag=v9.9.9-test
asset="twr-x86_64-unknown-linux-musl.tar.gz"
cleanup() {
    docker rm -f "$name" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail=0
pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
in_ct() { docker exec "$name" "$@"; }

# The image: Ubuntu with systemd and what cloud-init's packages: list installs.
cat > "$work/Dockerfile" << EOF
FROM $image
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \\
    systemd systemd-sysv dbus ca-certificates curl openssl python3 iproute2 \\
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
echo "building the test image from $image ..."
docker build -q -t twr-droplet-test:local "$work" > /dev/null

# A release signed with a throwaway key, as twr's release workflow lays it out.
openssl genpkey -algorithm ed25519 -out "$work/key.pem" 2> /dev/null
openssl pkey -in "$work/key.pem" -pubout -out "$work/key.pub"
make_release() { # DIR BINARY
    mkdir -p "$1/stage"
    cp "$2" "$1/stage/twr"
    chmod 0755 "$1/stage/twr"
    tar -C "$1/stage" -czf "$1/$asset" twr
    rm -r "$1/stage"
    {
        printf '# twr release %s\n' "$tag"
        printf '%s  %s\n' "$(sha256sum "$1/$asset" | awk '{ print $1 }')" "$asset"
    } > "$1/sha256sums.txt"
    openssl pkeyutl -sign -rawin -inkey "$work/key.pem" -in "$1/sha256sums.txt" |
        openssl base64 -A > "$1/sha256sums.txt.sig"
}

# The bundle deploy-regions.sh uploads, with relay.toml from $2.
make_bundle() { # DIR RELEASE_DIR CONFIG
    mkdir -p "$1/release" "$1/monitoring/systemd"
    cp scripts/install-twr-release.sh scripts/apply-release.sh "$1/"
    cp "$work/key.pub" "$1/twr-release-signing-key.pub"
    cp "$2"/* "$1/release/"
    cp "$3" "$1/relay.toml"
    cp monitoring/*.sh monitoring/alert.env.example "$1/monitoring/"
    cp monitoring/systemd/* "$1/monitoring/systemd/"
}
apply() { # BUNDLE_DIR
    docker exec "$name" rm -rf /root/bundle
    docker cp -q "$1" "$name:/root/bundle"
    docker exec "$name" sh /root/bundle/apply-release.sh --tag "$tag" --region eu \
        --bundle /root/bundle --peers us --domain relay.twr.tools
}

sed 's/^mode = "acme"/mode = "self-signed"/' config/eu.toml > "$work/eu-self-signed.toml"
grep -q '^mode = "self-signed"' "$work/eu-self-signed.toml" || { echo "config/eu.toml has no tls mode line to switch" >&2; exit 1; }
"$twr" relay check-config "$work/eu-self-signed.toml" > /dev/null

make_release "$work/rel-good" "$twr"
make_bundle "$work/b-good" "$work/rel-good" "$work/eu-self-signed.toml"

docker run -d --name "$name" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    --add-host eu.relay.twr.tools:127.0.0.1 --add-host iroh.eu.relay.twr.tools:127.0.0.1 \
    twr-droplet-test:local > /dev/null
i=0
until in_ct systemctl is-system-running > /dev/null 2>&1 || [ "$(in_ct systemctl is-system-running 2> /dev/null)" = degraded ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { echo "systemd didn't come up in the container" >&2; exit 1; }
    sleep 1
done
# shellcheck disable=SC2016 # expanded in the container
echo "container: $(in_ct sh -c '. /etc/os-release; echo "$PRETTY_NAME"'), systemd $(in_ct systemctl --version | awk 'NR == 1 { print $2 }')"

# 1. First deploy.
if apply "$work/b-good" > "$work/apply1.log" 2>&1; then pass "first deploy"; else bad "first deploy"; cat "$work/apply1.log"; fi
if in_ct systemctl is-active --quiet twr-relay.service; then pass "twr-relay is active"; else bad "twr-relay is not active"; in_ct journalctl -u twr-relay -n 30 --no-pager || true; fi
[ "$(in_ct stat -c '%U %a' /etc/twr-relay/relay.toml)" = "root 644" ] && pass "relay.toml root 0644" || bad "relay.toml owner/mode: $(in_ct stat -c '%U %a' /etc/twr-relay/relay.toml)"
[ "$(in_ct systemctl show -p User --value twr-relay.service)" = twr-relay ] && pass "the service runs as twr-relay" || bad "the service's user is $(in_ct systemctl show -p User --value twr-relay.service)"
in_ct cmp -s /etc/twr-relay/relay.toml /root/bundle/relay.toml && pass "relay.toml is the bundle's" || bad "relay.toml differs from the bundle's"
for t in twr-relay-peer-probe.timer twr-relay-local-check.timer; do
    in_ct systemctl is-active --quiet "$t" && pass "$t active" || bad "$t not active"
done
in_ct curl -fsS --max-time 5 http://127.0.0.1:9469/metrics | grep -q '^twr_relay_up 1' && pass "metrics: twr_relay_up 1" || bad "no twr_relay_up 1 on 127.0.0.1:9469"

# 2. The probe, inside the container, against the deployed relay (pinned: self-signed here).
url=$(in_ct /usr/local/bin/twr relay url --config /etc/twr-relay/relay.toml)
if in_ct /usr/local/bin/twr relay probe "$url" --connect 127.0.0.1:443 --state /root/probe > "$work/probe.log" 2>&1; then
    pass "probe $url"
else
    bad "probe $url"
    cat "$work/probe.log"
fi

# 3. The local check runs and finds nothing wrong (no alert route: it would only log).
if in_ct systemctl start twr-relay-local-check.service; then pass "local-check ran"; else bad "local-check failed"; in_ct journalctl -u twr-relay-local-check -n 20 --no-pager || true; fi

# 4. The same release again: twr.prev kept, still active.
if apply "$work/b-good" > "$work/apply2.log" 2>&1 && in_ct test -x /usr/local/bin/twr.prev && in_ct systemctl is-active --quiet twr-relay.service; then
    pass "second deploy keeps twr.prev and stays active"
else
    bad "second deploy"
    cat "$work/apply2.log"
fi

# 5. A config the new twr refuses: the deploy fails, the running config and service stay.
{ cat "$work/eu-self-signed.toml"; printf '\n[nonsense]\nkey = 1\n'; } > "$work/eu-bad.toml"
make_bundle "$work/b-badconf" "$work/rel-good" "$work/eu-bad.toml"
before=$(in_ct sha256sum /etc/twr-relay/relay.toml)
if apply "$work/b-badconf" > "$work/apply3.log" 2>&1; then
    bad "a refused config deployed"
else
    [ "$(in_ct sha256sum /etc/twr-relay/relay.toml)" = "$before" ] && in_ct systemctl is-active --quiet twr-relay.service &&
        pass "refused config: deploy failed, config and service unchanged" || bad "refused config left things changed"
fi

# 6. A release whose relay doesn't start: the deploy rolls back to the previous twr.
cat > "$work/crash-twr" << 'EOF'
#!/bin/sh
case "$*" in
    --version) echo "twr 9.9.9-crash" ;;
    "relay check-config"*) echo "ok" ;;
    *) echo "this twr crashes" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$work/crash-twr"
make_release "$work/rel-crash" "$work/crash-twr"
make_bundle "$work/b-crash" "$work/rel-crash" "$work/eu-self-signed.toml"
good_sum=$(in_ct sha256sum /usr/local/bin/twr | awk '{ print $1 }')
if apply "$work/b-crash" > "$work/apply4.log" 2>&1; then
    bad "a crashing release deployed"
else
    if [ "$(in_ct sha256sum /usr/local/bin/twr | awk '{ print $1 }')" = "$good_sum" ] && in_ct systemctl is-active --quiet twr-relay.service; then
        pass "crashing release: rolled back, the previous twr is active"
    else
        bad "crashing release: no clean rollback"
        cat "$work/apply4.log"
    fi
fi
if in_ct /usr/local/bin/twr relay probe "$url" --connect 127.0.0.1:443 --state /root/probe > "$work/probe2.log" 2>&1; then
    pass "probe after the rollback"
else
    bad "probe after the rollback"
    cat "$work/probe2.log"
fi

# 7. The log holds no addresses.
if in_ct journalctl -u twr-relay --no-pager -o cat | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}|::1' > "$work/addr.log"; then
    bad "twr-relay's journal holds addresses:"
    cat "$work/addr.log"
else
    pass "twr-relay's journal holds no addresses"
fi

if [ "$fail" != 0 ]; then
    echo "test-droplet-container: FAILED"
    exit 1
fi
echo "test-droplet-container: all checks passed"
