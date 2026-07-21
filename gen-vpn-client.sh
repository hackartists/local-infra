#!/bin/bash
# Issue a VPN client profile: ./gen-vpn-client.sh <name> [out.ovpn]
set -euo pipefail
cd "$(dirname "$0")"

NAME="${1:?usage: $0 <client-name> [out.ovpn]}"
OUT="${2:-$NAME.ovpn}"

docker compose exec -T openvpn /usr/local/bin/openvpn-entrypoint.sh genclient "$NAME" > "$OUT"
echo "wrote $OUT"
