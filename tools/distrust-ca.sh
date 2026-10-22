#!/bin/sh
# Remove CA certificates whose subject matches a pattern, from the OpenWrt
# trust store, and rebuild the bundle. Use when a CA is compromised/withdrawn
# and you cannot just wait for a firmware upgrade.
#
#   sh distrust-ca.sh emSign            # dry-run: only list what would go
#   sh distrust-ca.sh emSign --apply    # actually remove
#
# Always keeps a timestamped backup of the bundle next to it.

BUNDLE=${BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
CERTS_DIR=${CERTS_DIR:-/etc/ssl/certs}

PATTERN=${1:-}
APPLY=0
[ "$2" = "--apply" ] && APPLY=1

[ -n "$PATTERN" ] || { echo "usage: sh $0 <subject-pattern> [--apply]"; exit 2; }
[ -f "$BUNDLE" ] || { echo "no bundle at $BUNDLE"; exit 1; }

echo "bundle : $BUNDLE ($(grep -c 'BEGIN CERTIFICATE' "$BUNDLE") certs)"
echo "filter : subject matching '$PATTERN'"

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# split bundle into single certs, keep order
awk -v dir="$WORK" 'BEGIN{n=0;inb=0}
     /-----BEGIN CERTIFICATE-----/{n++; f=sprintf("%s/%04d.pem", dir, n); inb=1}
     inb{print > f}
     /-----END CERTIFICATE-----/{inb=0; close(f)}' "$BUNDLE"

: > "$WORK/new.crt"
kept=0; dropped=0
for f in "$WORK"/*.pem; do
    subj=$(openssl x509 -in "$f" -noout -subject 2>/dev/null)
    if echo "$subj" | grep -qi -- "$PATTERN"; then
        echo "  DROP  $subj"
        dropped=$((dropped + 1))
        # remember the CN so the matching .crt / hash links can be removed
        echo "$subj" | sed -n 's/.*CN *= *//p' >> "$WORK/dropped.txt"
    else
        cat "$f" >> "$WORK/new.crt"
        kept=$((kept + 1))
    fi
done

echo "kept=$kept dropped=$dropped"

if [ "$dropped" = "0" ]; then
    echo "nothing matched, nothing changed"
    exit 0
fi

if [ "$APPLY" != "1" ]; then
    echo
    echo "dry-run only. re-run with --apply to write:"
    echo "  sh $0 '$PATTERN' --apply"
    exit 0
fi

TS=$(date +%s)
cp "$BUNDLE" "$BUNDLE.bak.$TS"
echo "backup: $BUNDLE.bak.$TS"
mv "$WORK/new.crt" "$BUNDLE"

# remove the per-cert files and their hash symlinks
while IFS= read -r cn; do
    [ -n "$cn" ] || continue
    f="$CERTS_DIR/$(echo "$cn" | tr ' ' '_').crt"
    [ -f "$f" ] && { rm -f "$f"; echo "  removed $f"; }
    for l in "$CERTS_DIR"/*.0; do
        [ -L "$l" ] || continue
        [ "$(readlink "$l")" = "$(basename "$f")" ] && { rm -f "$l"; echo "  removed link $l"; }
    done
done < "$WORK/dropped.txt"

echo
echo "now: $(grep -c 'BEGIN CERTIFICATE' "$BUNDLE") certs"
echo "verify with: curl -sS https://<a host issued by that CA>/"
