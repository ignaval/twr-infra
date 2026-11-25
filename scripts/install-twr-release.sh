#!/bin/sh
# install-twr-release.sh: fetch one signed twr release, check it, install the twr binary.
#
# One script for every place twr is installed from this repository:
#   - cloud-init, on a Droplet's first boot (downloads from GitHub);
#   - the deploy workflow on the runner (checks the release, keeps the files to upload, and
#     installs a twr for `twr relay probe`);
#   - apply-release.sh on each Droplet during a deploy (from the files the runner uploaded,
#     checked again here).
#
# It fails closed. Nothing is installed unless all of these hold:
#   1. the key file is an Ed25519 public key;
#   2. sha256sums.txt.sig is an Ed25519 signature (base64 of 64 bytes) of sha256sums.txt that
#      verifies under that key (openssl pkeyutl -verify -rawin, OpenSSL 3.0 or newer);
#   3. sha256sums.txt names exactly one release, `# twr release <tag>`, and it is --tag;
#   4. the archive's SHA-256 is the one sha256sums.txt lists for it;
#   5. the archive holds a regular file `twr` at the top level, and (when installing) it runs.
# This mirrors what twr's own install.sh checks (release/signing-key.pub, sha256sums.txt).
#
# usage: install-twr-release.sh --tag TAG [options]
#   --tag TAG         the release tag, for example v0.8.0 (required)
#   --key FILE        the release public key, PEM
#                     (default /usr/local/share/twr-infra/twr-release-signing-key.pub)
#   --arch ARCH       x86_64 or aarch64 (default: this machine's)
#   --from-dir DIR    take the release files from DIR instead of downloading them
#   --keep-dir DIR    copy the checked release files into DIR (created if missing)
#   --dest DIR        install the binary as DIR/twr (default /usr/local/bin)
#   --verify-only     check the release, install nothing
#   --repo OWNER/REPO the GitHub repository (default ignaval/twr)
#
# Release files (twr's .github/workflows/release.yml): twr-<arch>-unknown-linux-musl.tar.gz,
# sha256sums.txt and sha256sums.txt.sig, at https://github.com/<repo>/releases/download/<tag>/.

set -eu
umask 022

prog=install-twr-release
tag=""
key=/usr/local/share/twr-infra/twr-release-signing-key.pub
arch=""
from_dir=""
keep_dir=""
dest=/usr/local/bin
verify_only=""
repo=ignaval/twr

say() {
    printf '%s: %s\n' "$prog" "$*" >&2
}

err() {
    printf '%s: error: %s; nothing was installed\n' "$prog" "$*" >&2
    exit 1
}

usage() {
    sed -n '/^# usage:/,/^# Release files/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

need_value() {
    [ "$2" -ge 2 ] || err "$1 needs a value"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) need_value "$1" $#; tag=$2; shift 2 ;;
        --key) need_value "$1" $#; key=$2; shift 2 ;;
        --arch) need_value "$1" $#; arch=$2; shift 2 ;;
        --from-dir) need_value "$1" $#; from_dir=$2; shift 2 ;;
        --keep-dir) need_value "$1" $#; keep_dir=$2; shift 2 ;;
        --dest) need_value "$1" $#; dest=$2; shift 2 ;;
        --verify-only) verify_only=1; shift ;;
        --repo) need_value "$1" $#; repo=$2; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) err "unknown argument: $1 (see --help)" ;;
    esac
done

# The tag goes into a URL and into a comparison: a strict shape only.
case "$tag" in
    "") err "--tag is required" ;;
    v[0-9]*) ;;
    *) err "--tag $tag is not a release tag (v<version>)" ;;
esac
case "$tag" in
    *[!A-Za-z0-9.+-]*) err "--tag $tag has characters a release tag doesn't" ;;
esac
case "$repo" in
    */*/* | *[!A-Za-z0-9._/-]*) err "--repo $repo is not OWNER/REPO" ;;
    [A-Za-z0-9]*/[A-Za-z0-9]*) ;;
    *) err "--repo $repo is not OWNER/REPO" ;;
esac

if [ -z "$arch" ]; then
    arch=$(uname -m)
fi
case "$arch" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) err "unsupported CPU architecture: $arch (twr's Linux builds are x86_64 and aarch64)" ;;
esac
asset="twr-$arch-unknown-linux-musl.tar.gz"

for tool in openssl awk tar sha256sum wc tr mktemp; do
    command -v "$tool" > /dev/null 2>&1 || err "this machine has no $tool"
done
if [ -z "$from_dir" ]; then
    command -v curl > /dev/null 2>&1 || err "this machine has no curl"
fi
[ -f "$key" ] || err "no release key at $key"

work=$(mktemp -d "${TMPDIR:-/tmp}/twr-release.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# 1. The key must be Ed25519: pkeyutl -rawin means something else for other key types.
openssl pkey -pubin -in "$key" -noout -text 2> /dev/null | head -n 1 | grep -q '^ED25519 Public-Key' ||
    err "$key is not an Ed25519 public key (or this openssl can't read one; OpenSSL 3.0 or newer is needed)"

base="https://github.com/$repo/releases/download/$tag"
for f in "$asset" sha256sums.txt sha256sums.txt.sig; do
    if [ -n "$from_dir" ]; then
        [ -f "$from_dir/$f" ] || err "$from_dir has no $f"
        cp "$from_dir/$f" "$work/$f" || err "could not copy $from_dir/$f"
    else
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 20 \
            --max-time 600 -o "$work/$f" "$base/$f" || err "could not download $base/$f"
    fi
done

# 2. The signature: base64 text (88 characters) of a raw 64-byte Ed25519 signature.
sig_text=$(tr -d '\r\n' < "$work/sha256sums.txt.sig")
case "$sig_text" in
    "" | *[!A-Za-z0-9+/=]*) err "sha256sums.txt.sig is not base64" ;;
esac
[ "${#sig_text}" -eq 88 ] || err "sha256sums.txt.sig is not an Ed25519 signature (${#sig_text} characters, not 88)"
printf '%s' "$sig_text" | openssl base64 -d -A > "$work/sig.bin" 2> /dev/null ||
    err "sha256sums.txt.sig does not decode"
[ "$(wc -c < "$work/sig.bin" | tr -d ' ')" = 64 ] || err "sha256sums.txt.sig does not decode to 64 bytes"
openssl pkeyutl -verify -rawin -pubin -inkey "$key" -sigfile "$work/sig.bin" \
    -in "$work/sha256sums.txt" > /dev/null 2>&1 ||
    err "the signature of sha256sums.txt does not verify with $key"

# 3. The signed checksums must be this release's, so another release's can't be swapped in.
release=$(awk -v p='# twr release ' 'index($0, p) == 1 { n++; t = substr($0, length(p) + 1) }
    END { if (n == 1) print t }' "$work/sha256sums.txt")
[ -n "$release" ] || err "sha256sums.txt does not name one release (a '# twr release <tag>' line)"
[ "$release" = "$tag" ] || err "sha256sums.txt is the checksums of $release, not of $tag"

# 4. The archive's checksum.
expected=$(awk -v f="$asset" '$2 == f || $2 == "*" f { n++; h = $1 } END { if (n == 1) print h }' \
    "$work/sha256sums.txt")
case "$expected" in
    "") err "$asset is not listed exactly once in sha256sums.txt" ;;
    *[!0-9a-f]*) err "the checksum listed for $asset is not lowercase hex" ;;
esac
[ "${#expected}" -eq 64 ] || err "the checksum listed for $asset is not a SHA-256"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || err "checksum mismatch for $asset (expected $expected, got $actual)"
say "$asset of $tag: signature and checksum verified"

# 5. The binary.
mkdir "$work/x"
tar -xzf "$work/$asset" -C "$work/x" twr 2> /dev/null || err "$asset has no top-level twr"
if [ ! -f "$work/x/twr" ] || [ -L "$work/x/twr" ]; then err "twr in $asset is not a regular file"; fi

if [ -n "$keep_dir" ]; then
    mkdir -p "$keep_dir" || err "could not create $keep_dir"
    for f in "$asset" sha256sums.txt sha256sums.txt.sig; do
        cp "$work/$f" "$keep_dir/$f" || err "could not copy $f to $keep_dir"
    done
    say "kept the checked release files in $keep_dir"
fi

if [ -n "$verify_only" ]; then
    say "verified only (--verify-only)"
    exit 0
fi

chmod 0755 "$work/x/twr"
version=$("$work/x/twr" --version 2> /dev/null) || err "the twr binary of $asset does not run on this machine"
mkdir -p "$dest" || err "could not create $dest"
# Staged next to the target and renamed over it: a running twr keeps its old inode.
staged="$dest/.twr.new.$$"
trap 'rm -rf "$work"; rm -f "$staged"' EXIT
cp "$work/x/twr" "$staged" || err "could not write $staged"
chmod 0755 "$staged"
mv -f "$staged" "$dest/twr" || err "could not install $dest/twr"
say "installed $dest/twr ($version)"
