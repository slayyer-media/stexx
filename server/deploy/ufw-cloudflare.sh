#!/usr/bin/env bash
#
# Firewall: ssh + Cloudflare-only HTTP(S). Run ON THE SERVER as root.
#
#   sudo ./ufw-cloudflare.sh            # dry run: prints what it would do
#   sudo ./ufw-cloudflare.sh --apply    # applies and enables ufw
#
# Env: SSH_ALLOW_FROM="203.0.113.7 198.51.100.0/24"  restrict ssh to these sources (default: anywhere, rate-limited)
#      SSH_PORT=22
#
# Why Cloudflare-only: api.stexx.gay and media.stexx.gay sit behind Cloudflare. If the origin answered anyone,
# a scanner could bypass Cloudflare (WAF, rate limiting, hidden origin IP). With 80/443 open only to
# Cloudflare's ranges, direct hits to the origin IP just time out. Postgres (5432) and the app (8787) are
# loopback-only and never opened here.
#
# ACME (Let's Encrypt HTTP-01) still works: validation requests arrive via Cloudflare's proxy.
# Re-run this monthly (or from a timer) to follow Cloudflare's published ranges; it replaces its own rules only.

set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
SSH_PORT="${SSH_PORT:-22}"
TAG="stexx-cloudflare"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
command -v ufw >/dev/null || { echo "ufw not installed (apt install ufw)" >&2; exit 1; }

fetch() {
  curl -fsS --max-time 20 --retry 2 "https://www.cloudflare.com/ips-$1"
}
V4="$(fetch v4)"
V6="$(fetch v6)"

CIDR4='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
CIDR6='^[0-9a-fA-F:]+/[0-9]{1,3}$'
ranges=()
while IFS= read -r line; do
  line="${line%%$'\r'}"
  [ -z "$line" ] && continue
  if [[ "$line" =~ $CIDR4 || "$line" =~ $CIDR6 ]]; then ranges+=("$line"); else echo "unexpected line from Cloudflare: '$line'" >&2; exit 1; fi
done <<< "$V4"$'\n'"$V6"
[ "${#ranges[@]}" -ge 10 ] || { echo "only ${#ranges[@]} ranges fetched; refusing to continue (would risk locking out traffic)" >&2; exit 1; }

say() { echo "+ $*"; if [ "$APPLY" = 1 ]; then "$@"; fi; }

# Remove our previous Cloudflare rules (tagged by comment) so removed ranges do not linger.
# Delete from the highest number down so numbering stays valid.
if [ "$APPLY" = 1 ]; then
  while read -r n; do
    [ -n "$n" ] && ufw --force delete "$n" >/dev/null
  done < <(ufw status numbered | grep "$TAG" | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)
fi

say ufw default deny incoming
say ufw default allow outgoing
say ufw logging off   # blocked-packet logs would contain source IPs; we do not want them

if [ -n "${SSH_ALLOW_FROM:-}" ]; then
  for src in $SSH_ALLOW_FROM; do say ufw allow from "$src" to any port "$SSH_PORT" proto tcp comment "stexx-ssh"; done
else
  say ufw limit "${SSH_PORT}/tcp" comment "stexx-ssh"
fi

for r in "${ranges[@]}"; do
  say ufw allow proto tcp from "$r" to any port 80,443 comment "$TAG"
done

if [ "$APPLY" = 1 ]; then
  grep -q '^IPV6=yes' /etc/default/ufw || echo "WARNING: IPV6 is not enabled in /etc/default/ufw; IPv6 rules above are inert" >&2
  ufw --force enable
  ufw status verbose | head -20
  echo "ufw active. Cloudflare ranges: ${#ranges[@]}."
else
  echo "dry run only (${#ranges[@]} Cloudflare ranges). Re-run with --apply."
fi
