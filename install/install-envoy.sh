#!/bin/bash
# Install or update Envoy from the official release binary, verified against the Envoy
# maintainers' release key. Any glibc Linux on x86_64 or aarch64 (Arch, Ubuntu, Debian, ...);
# Envoy's apt repository is unmaintained, so this is also the route on Ubuntu.
#
# Usage, as root:  install/install-envoy.sh <version>          e.g. 1.40.2
# Run it from a clean clone that no box mounts: as root it trusts this repo's key and code.
# Each version lands in /usr/local/libexec/airlock-envoy/envoy-<version>, and
# /usr/local/bin/envoy is switched to it atomically. Older versions stay for rollback.
set -euo pipefail

# Envoy maintainers <envoy-maintainers@googlegroups.com>: signed every release checked from
# v1.25.0 (2023-01) to v1.40.2 (2026-10). A different key stops the install.
FPR=0AFCE836BA4D1D35763C8523D8CDC3750181F31F

ver="${1:?usage: install-envoy.sh <version>, e.g. 1.40.2}"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.40.2" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for t in curl gpg sha256sum setpriv; do
  command -v "$t" >/dev/null || { echo "missing $t (Ubuntu: apt install curl gpg util-linux)" >&2; exit 1; }
done
case "$(uname -m)" in
  x86_64) arch=x86_64 ;;
  aarch64) arch=aarch_64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
bin="envoy-$ver-linux-$arch"
url="https://github.com/envoyproxy/envoy/releases/download/v$ver"
dest=/usr/local/libexec/airlock-envoy

# A fixed root-owned location (not $TMPDIR, which sudo -E could point somewhere you control),
# and curl without ~/.curlrc.
unset TMPDIR
work="$(mktemp -d /tmp/airlock-envoy-install.XXXXXX)"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --import "$here/envoy-release-key.asc"
gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" { print $10; exit }' | grep -qx "$FPR" \
  || { echo "the bundled key is not $FPR" >&2; exit 1; }

echo "==> Downloading Envoy $ver ($arch)"
curl -q -fsSL --proto '=https' --tlsv1.2 -o "$work/checksums.txt.asc" "$url/checksums.txt.asc"
curl -q -fsSL --proto '=https' --tlsv1.2 -o "$work/$bin" "$url/$bin"

# VALIDSIG <signing key fpr> ... <primary key fpr>: the primary must be the pinned key, and no
# revoked, expired or bad signature may appear alongside it.
rc=0
gpg --batch --status-fd 1 --verify "$work/checksums.txt.asc" 2>/dev/null > "$work/status" || rc=$?
awk -v f="$FPR" '$2 == "VALIDSIG" && $NF == f { ok = 1 }
  $2 ~ /^(REVKEYSIG|EXPKEYSIG|EXPSIG|BADSIG|ERRSIG|ERROR|FAILURE|NODATA)$/ { bad = 1 }
  END { exit !(ok && !bad) }' "$work/status" && [ "$rc" = 0 ] \
  || { echo "checksums.txt.asc is not validly signed by $FPR" >&2; exit 1; }
# Older releases list a build path (/tmp/.../bin/envoy-...), newer ones the bare name: match
# on the file name. The list is signed, so the path part carries no meaning.
gpg --batch --quiet --decrypt "$work/checksums.txt.asc" 2>/dev/null > "$work/list" \
  || { echo "cannot extract the signed checksum list" >&2; exit 1; }
awk -v f="$bin" '{ n = $2; sub(/.*\//, "", n) } n == f && !done { print $1 "  " f; done = 1 }' \
  "$work/list" > "$work/sum"
[ -s "$work/sum" ] || { echo "no checksum for $bin in the signed list" >&2; exit 1; }
(cd "$work" && sha256sum --quiet -c sum)
echo "    signature and checksum verified"

install -d -m 0755 -o root -g root "$dest"
install -m 0755 -o root -g root "$work/$bin" "$dest/.envoy-$ver.new"
# A version check, run as nobody rather than root.
got="$(setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs "$dest/.envoy-$ver.new" --version)"
[[ "$got" == *"/$ver/"* ]] || { rm -f "$dest/.envoy-$ver.new"; echo "unexpected version output: $got" >&2; exit 1; }
mv -f "$dest/.envoy-$ver.new" "$dest/envoy-$ver"
ln -sfn "$dest/envoy-$ver" /usr/local/bin/envoy.new
mv -Tf /usr/local/bin/envoy.new /usr/local/bin/envoy
echo "==> /usr/local/bin/envoy -> $dest/envoy-$ver"
if systemctl is-active --quiet airlock-envoy 2>/dev/null; then
  echo "    running service: systemctl restart airlock-envoy (open tunnels drop; box sockets stay)"
fi
