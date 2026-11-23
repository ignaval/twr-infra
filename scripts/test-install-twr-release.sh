#!/bin/sh
# test-install-twr-release.sh: offline tests of install-twr-release.sh against a fake release
# signed with a throwaway Ed25519 key. Checks that a good release installs and that every
# tampered one installs nothing. Needs openssl 3, tar, sha256sum. Writes only under $TMPDIR.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
script="$here/install-twr-release.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/twr-release-test.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

fails=0
asset=twr-x86_64-unknown-linux-musl.tar.gz

# make_release DIR TAG: a release DIR with a fake twr, its checksums and their signature.
make_release() {
    mkdir -p "$1/stage"
    printf '#!/bin/sh\necho "twr 0.0.0-test"\n' > "$1/stage/twr"
    chmod 0755 "$1/stage/twr"
    tar -C "$1/stage" -czf "$1/$asset" twr
    rm -r "$1/stage"
    {
        printf '# twr release %s\n' "$2"
        printf '%s  %s\n' "$(sha256sum "$1/$asset" | awk '{ print $1 }')" "$asset"
    } > "$1/sha256sums.txt"
    sign "$1" "$work/key.pem"
}

# sign DIR KEY: (re)writes DIR/sha256sums.txt.sig as the release workflow does.
sign() {
    openssl pkeyutl -sign -rawin -inkey "$2" -in "$1/sha256sums.txt" | openssl base64 -A > "$1/sha256sums.txt.sig"
}

# run NAME EXPECT DIR TAG [KEY]: runs the installer and checks the outcome.
run() {
    name=$1 expect=$2 dir=$3 tag=$4 key=${5:-$work/key.pub}
    dest="$work/dest-$name"
    if sh "$script" --tag "$tag" --key "$key" --arch x86_64 --from-dir "$dir" --dest "$dest" \
        > "$work/$name.log" 2>&1; then
        got=ok
    else
        got=fail
    fi
    if [ "$got" != "$expect" ]; then
        printf 'FAIL %s: expected %s, got %s\n' "$name" "$expect" "$got"
        sed 's/^/    /' "$work/$name.log"
        fails=$((fails + 1))
        return
    fi
    if [ "$expect" = ok ] && ! "$dest/twr" --version > /dev/null 2>&1; then
        printf 'FAIL %s: installed nothing runnable\n' "$name"
        fails=$((fails + 1))
        return
    fi
    if [ "$expect" = fail ] && [ -e "$dest/twr" ]; then
        printf 'FAIL %s: refused but installed %s/twr\n' "$name" "$dest"
        fails=$((fails + 1))
        return
    fi
    printf 'ok   %s (%s: %s)\n' "$name" "$got" "$(tail -n 1 "$work/$name.log")"
}

openssl genpkey -algorithm ed25519 -out "$work/key.pem" 2> /dev/null
openssl pkey -in "$work/key.pem" -pubout -out "$work/key.pub"
openssl genpkey -algorithm ed25519 -out "$work/other.pem" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/ec.pem" 2> /dev/null
openssl pkey -in "$work/ec.pem" -pubout -out "$work/ec.pub"

make_release "$work/good" v0.0.1
run good ok "$work/good" v0.0.1

run wrong-tag fail "$work/good" v0.0.2
run not-a-tag fail "$work/good" latest
run ec-key fail "$work/good" v0.0.1 "$work/ec.pub"

cp -R "$work/good" "$work/other-key"
sign "$work/other-key" "$work/other.pem"
run other-key fail "$work/other-key" v0.0.1

cp -R "$work/good" "$work/archive-changed"
printf 'x' >> "$work/archive-changed/$asset"
run archive-changed fail "$work/archive-changed" v0.0.1

cp -R "$work/good" "$work/sums-changed"
printf '%s  extra\n' "$(printf '0%.0s' $(seq 64))" >> "$work/sums-changed/sha256sums.txt"
run sums-changed fail "$work/sums-changed" v0.0.1

cp -R "$work/good" "$work/no-sig"
rm "$work/no-sig/sha256sums.txt.sig"
run no-sig fail "$work/no-sig" v0.0.1

cp -R "$work/good" "$work/short-sig"
printf 'AAAA' > "$work/short-sig/sha256sums.txt.sig"
run short-sig fail "$work/short-sig" v0.0.1

cp -R "$work/good" "$work/two-releases"
printf '# twr release v0.0.1\n' >> "$work/two-releases/sha256sums.txt"
sign "$work/two-releases" "$work/key.pem"
run two-releases fail "$work/two-releases" v0.0.1

cp -R "$work/good" "$work/unlisted"
sed -i "s/$asset/twr-other.tar.gz/" "$work/unlisted/sha256sums.txt"
sign "$work/unlisted" "$work/key.pem"
run unlisted fail "$work/unlisted" v0.0.1

mkdir -p "$work/no-binary/stage"
printf 'hello\n' > "$work/no-binary/stage/README.md"
tar -C "$work/no-binary/stage" -czf "$work/no-binary/$asset" README.md
{
    printf '# twr release v0.0.1\n'
    printf '%s  %s\n' "$(sha256sum "$work/no-binary/$asset" | awk '{ print $1 }')" "$asset"
} > "$work/no-binary/sha256sums.txt"
sign "$work/no-binary" "$work/key.pem"
run no-binary fail "$work/no-binary" v0.0.1

# --verify-only and --keep-dir: checks, keeps the files, installs nothing.
if sh "$script" --tag v0.0.1 --key "$work/key.pub" --arch x86_64 --from-dir "$work/good" \
    --keep-dir "$work/kept" --dest "$work/dest-verify-only" --verify-only > "$work/vo.log" 2>&1 &&
    [ ! -e "$work/dest-verify-only/twr" ] && [ -f "$work/kept/sha256sums.txt.sig" ]; then
    echo "ok   verify-only (kept the files, installed nothing)"
else
    echo "FAIL verify-only"
    sed 's/^/    /' "$work/vo.log"
    fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
    echo "$fails test(s) failed"
    exit 1
fi
echo "all install-twr-release.sh tests passed"
