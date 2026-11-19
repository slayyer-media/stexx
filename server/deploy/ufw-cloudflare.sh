#!/usr/bin/env bash
#
# Firewall: ssh + Cloudflare-only HTTP(S). Run ON THE SERVER as root.
#
#   sudo ./ufw-cloudflare.sh                          # dry run: prints what it would do
#   sudo ./ufw-cloudflare.sh --apply                  # applies and enables ufw
#   sudo ./ufw-cloudflare.sh --apply --tailscale-admin   # also allow the staff console's port on tailscale0
#
# Env: SSH_ALLOW_FROM="203.0.113.7 198.51.100.0/24"  restrict ssh to these sources (default: anywhere, rate-limited)
#      SSH_PORT=22
#      STEXX_ADMIN_TAILSCALE=1                       same as --tailscale-admin
#      STEXX_ADMIN_PORT=8443                         the console's port. Read from /etc/stexx/caddy-admin.env when that
#                                                    exists (what Caddy listens on); setting a different one here is refused
#
# Why Cloudflare-only: api.stexx.gay and media.stexx.gay sit behind Cloudflare. If the origin answered anyone,
# a scanner could bypass Cloudflare (WAF, rate limiting, hidden origin IP). With 80/443 open only to
# Cloudflare's ranges, direct hits to the origin IP just time out. Postgres (5432) and the app (8787) are
# loopback-only and never opened here.
#
# --tailscale-admin (opt-in): the private staff console (deploy/Caddyfile.admin) answers on its own port (default 8443,
# not 443: Caddy can't share 443 with the public sites and stay off the public interface). This adds ONE rule, that
# port in on the tailscale0 interface, and nothing for the public interface. It is never added without the flag; a run
# with the flag replaces the earlier one (so a changed port leaves no stale rule), and a later run without the flag
# leaves an existing rule alone (remove it with `ufw status numbered` and `ufw delete N`, rule comment
# "stexx-admin-tailscale"). Tailscale ACLs decide which devices may reach it. Caddy listens on that port on every
# interface, so with the flag this refuses to run unless /etc/default/ufw has IPV6=yes: otherwise ufw installs no IPv6
# rules at all and the port would answer on the server's public IPv6 address.
#
# ACME (Let's Encrypt HTTP-01) still works: validation requests arrive via Cloudflare's proxy.
# Re-run this monthly (or from a timer) to follow Cloudflare's published ranges; it replaces its own rules only.

set -euo pipefail

APPLY=0
TS_ADMIN=0
[ "${STEXX_ADMIN_TAILSCALE:-0}" = 1 ] && TS_ADMIN=1
for arg in "$@"; do
  case "$arg" in
    --apply)            APPLY=1 ;;
    --tailscale-admin)  TS_ADMIN=1 ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *)                  echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
SSH_PORT="${SSH_PORT:-22}"
ADMIN_PORT="${STEXX_ADMIN_PORT:-8443}"
CADDY_ADMIN_ENV="${STEXX_CADDY_ADMIN_ENV:-/etc/stexx/caddy-admin.env}"
if [ "$TS_ADMIN" = 1 ] && [ -f "$CADDY_ADMIN_ENV" ]; then
  # The port Caddy actually listens on (same default as Caddyfile.admin), whatever this shell has exported.
  # shellcheck source=/dev/null
  CADDY_PORT="$(unset STEXX_ADMIN_PORT; . "$CADDY_ADMIN_ENV"; printf '%s' "${STEXX_ADMIN_PORT:-8443}")"
  if [ -n "${STEXX_ADMIN_PORT:-}" ] && [ "$STEXX_ADMIN_PORT" != "$CADDY_PORT" ]; then
    echo "STEXX_ADMIN_PORT=$STEXX_ADMIN_PORT here, but $CADDY_ADMIN_ENV has the console on $CADDY_PORT: fix one of them" >&2; exit 2
  fi
  ADMIN_PORT="$CADDY_PORT"
fi
TAG="stexx-cloudflare"
TS_TAG="stexx-admin-tailscale"
if [[ ! "$ADMIN_PORT" =~ ^[0-9]{4,5}$ ]] || [ "$ADMIN_PORT" -lt 1024 ] || [ "$ADMIN_PORT" -gt 65535 ] || [ "$ADMIN_PORT" = 8787 ] || [ "$ADMIN_PORT" = 8788 ]; then
  echo "STEXX_ADMIN_PORT must be a port from 1024 to 65535 other than 8787 and 8788" >&2; exit 2
fi

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
command -v ufw >/dev/null || { echo "ufw not installed (apt install ufw)" >&2; exit 1; }
if [ "$TS_ADMIN" = 1 ] && ! grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  echo "--tailscale-admin: set IPV6=yes in /etc/default/ufw first. Without it ufw filters no IPv6 at all, and the console's" >&2
  echo "port (Caddy listens on every interface) would answer on the server's public IPv6 address. Nothing was changed." >&2
  exit 1
fi

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

# Remove our previous Cloudflare rules (tagged by comment) so removed ranges do not linger, and with --tailscale-admin
# the previous console rule too (it is added again below, for the current port).
# Delete from the highest number down so numbering stays valid.
OURS="$TAG"
[ "$TS_ADMIN" = 1 ] && OURS="$TAG|$TS_TAG"
if [ "$APPLY" = 1 ]; then
  while read -r n; do
    [ -n "$n" ] && ufw --force delete "$n" >/dev/null
  done < <(ufw status numbered | grep -E "# ($OURS)\b" | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)
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

if [ "$TS_ADMIN" = 1 ]; then
  # Interface-scoped: a packet arriving on the public interface never matches, whatever address it claims.
  say ufw allow in on tailscale0 to any port "$ADMIN_PORT" proto tcp comment "$TS_TAG"
  if [ "$APPLY" = 1 ] && ! ip link show tailscale0 >/dev/null 2>&1; then
    echo "WARNING: no tailscale0 interface yet (is tailscaled up?). The rule is in place for when it appears." >&2
  fi
fi

if [ "$APPLY" = 1 ]; then
  grep -q '^IPV6=yes' /etc/default/ufw || echo "WARNING: IPV6 is not enabled in /etc/default/ufw; IPv6 rules above are inert" >&2
  ufw --force enable
  ufw status verbose | head -20
  echo "ufw active. Cloudflare ranges: ${#ranges[@]}."
else
  echo "dry run only (${#ranges[@]} Cloudflare ranges). Re-run with --apply."
fi
