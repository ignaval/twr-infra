#!/bin/sh
# check-cloud-init.sh: renders each region's first-boot cloud-init with tofu itself
# (local.user_data in tofu/main.tf, with tofu/tests/check.tfvars) and checks it against
# cloud-init's own schema. Contacts nothing, but needs `tofu init` done in tofu/ (it reads the
# provider schema) and the cloud-init package (`cloud-init schema`).
#
#   sh scripts/check-cloud-init.sh
set -eu
cd "$(dirname "$0")/.."

if [ ! -d tofu/.terraform ]; then
    echo "tofu/ isn't initialised: run tofu -chdir=tofu init -backend=false" >&2
    exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

echo 'jsonencode(local.user_data)' |
    tofu -chdir=tofu console -var-file=tests/check.tfvars > "$work/user_data.json"
regions=$(python3 -I -c 'import json,sys; print(" ".join(sorted(json.loads(json.load(open(sys.argv[1]))))))' "$work/user_data.json")
[ -n "$regions" ] || { echo "no regions rendered" >&2; exit 1; }

fail=0
for r in $regions; do
    python3 -I -c 'import json,sys; sys.stdout.write(json.loads(json.load(open(sys.argv[1])))[sys.argv[2]])' \
        "$work/user_data.json" "$r" > "$work/$r.yaml"
    echo "== $r: $(wc -c < "$work/$r.yaml") bytes"
    # cloud-init warns about this machine's own datasource; show its stderr only on failure.
    if cloud-init schema --config-file "$work/$r.yaml" --annotate > "$work/$r.out" 2>&1; then
        grep -v WARNING "$work/$r.out" | sed "s|$work/||"
    else
        cat "$work/$r.out"
        fail=1
    fi
done
exit "$fail"
