#!/bin/bash
# OpenVPN server for the k3s cluster (runs as a pod, privileged, hostPort udp).
#
# Clients get a split tunnel: only the cluster service/pod CIDRs (plus any
# extra routes) go through the VPN, and DNS is served by an in-pod dnsmasq
# that forwards cluster zones to CoreDNS — so cluster names
# (postgres.infra.svc.cluster.local, or just "postgres" via the pushed search
# domains) resolve for VPN clients exactly like they do inside the cluster.
#
# Usage:
#   openvpn-entrypoint.sh server            # default CMD — init PKI and run
#   openvpn-entrypoint.sh genclient <name>  # print an inline .ovpn to stdout
#   openvpn-entrypoint.sh revoke <name>     # revoke a client certificate
set -euo pipefail

OVPN_DIR=/etc/openvpn
PKI_DIR="$OVPN_DIR/pki"
EASYRSA=/usr/share/easy-rsa/easyrsa
export EASYRSA_PKI="$PKI_DIR"
export EASYRSA_BATCH=1

OVPN_PORT="${OVPN_PORT:-1194}"
OVPN_SUBNET="${OVPN_SUBNET:-10.8.0.0}"
OVPN_NETMASK="${OVPN_NETMASK:-255.255.255.0}"
OVPN_GATEWAY="${OVPN_GATEWAY:-10.8.0.1}"
# Public endpoint clients connect to, as "host port".
OVPN_REMOTE="${OVPN_REMOTE:-vpn.miner.biyard.co 1194}"
# Network(s) routed to clients, as "network netmask"; multiple entries are
# separated by ';'. A single host is "<ip> 255.255.255.255".
OVPN_PUSH_ROUTE="${OVPN_PUSH_ROUTE:-10.43.0.0 255.255.0.0;10.42.0.0 255.255.0.0}"
# DNS search domains pushed to clients, ';'-separated. Lets short names like
# "postgres" resolve to postgres.<first domain>.
OVPN_PUSH_DOMAIN="${OVPN_PUSH_DOMAIN:-infra.svc.cluster.local;svc.cluster.local;cluster.local}"
# Zones dnsmasq forwards to the cluster DNS instead of public resolvers,
# ';'-separated. Defaults cover cluster names + reverse lookups for the k3s
# service (10.43/16) and pod (10.42/16) CIDRs.
OVPN_CLUSTER_DOMAINS="${OVPN_CLUSTER_DOMAINS:-cluster.local;43.10.in-addr.arpa;42.10.in-addr.arpa}"
# Cluster DNS server; defaults to the pod's own resolver (CoreDNS in k8s).
OVPN_CLUSTER_DNS="${OVPN_CLUSTER_DNS:-$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)}"

push_routes() {
  local IFS=';'
  local route
  for route in $OVPN_PUSH_ROUTE; do
    route="$(echo "$route" | xargs)"
    [ -n "$route" ] && echo "push \"route $route\""
  done
}

push_domains() {
  local IFS=';'
  local domain
  for domain in $OVPN_PUSH_DOMAIN; do
    domain="$(echo "$domain" | xargs)"
    [ -n "$domain" ] || continue
    # DOMAIN for OpenVPN Connect (split-DNS match + search); DOMAIN-SEARCH
    # for Tunnelblick/Windows, which only add search domains from that token.
    echo "push \"dhcp-option DOMAIN $domain\""
    echo "push \"dhcp-option DOMAIN-SEARCH $domain\""
  done
}

cluster_dns_servers() {
  local IFS=';'
  local zone
  for zone in $OVPN_CLUSTER_DOMAINS; do
    zone="$(echo "$zone" | xargs)"
    [ -n "$zone" ] && echo "server=/$zone/$OVPN_CLUSTER_DNS"
  done
}

init_pki() {
  if [ ! -f "$PKI_DIR/ca.crt" ]; then
    echo ">> initializing PKI" >&2
    "$EASYRSA" init-pki >&2
    EASYRSA_REQ_CN="biyard-vpn-ca" "$EASYRSA" build-ca nopass >&2
  fi
  if [ ! -f "$PKI_DIR/issued/server.crt" ]; then
    "$EASYRSA" build-server-full server nopass >&2
  fi
  if [ ! -f "$OVPN_DIR/ta.key" ]; then
    openvpn --genkey secret "$OVPN_DIR/ta.key"
  fi
}

write_server_conf() {
  cat > "$OVPN_DIR/server.conf" <<EOF
port $OVPN_PORT
proto udp
dev tun
topology subnet
server $OVPN_SUBNET $OVPN_NETMASK

ca $PKI_DIR/ca.crt
cert $PKI_DIR/issued/server.crt
key $PKI_DIR/private/server.key
dh none
tls-crypt $OVPN_DIR/ta.key

data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256
remote-cert-tls client

$(push_routes)
push "dhcp-option DNS $OVPN_GATEWAY"
$(push_domains)
# Make split-DNS clients (OpenVPN Connect on macOS/iOS/Windows) send ALL
# domains to the VPN DNS, not just VPN-scoped ones. Other clients ignore it.
push "dhcp-option DOMAIN-ROUTE ."

keepalive 10 60
explicit-exit-notify 1
persist-key
persist-tun
status /run/openvpn-status.log
verb 3
EOF
}

write_dnsmasq_conf() {
  cat > /etc/dnsmasq.conf <<EOF
port=53
no-resolv
no-hosts
# Cluster zones (cluster.local + service/pod CIDR reverse zones) -> CoreDNS;
# everything else goes straight to public resolvers so VPN clients keep
# normal internet DNS while cluster names resolve like in-cluster.
$(cluster_dns_servers)
server=1.1.1.1
server=8.8.8.8
bind-dynamic
interface=tun0
interface=lo
log-queries
log-facility=/var/log/dnsmasq.log
EOF
}

setup_nat() {
  # In k8s the pod netns doesn't inherit ip_forward; the pod runs privileged
  # so we can set it ourselves instead of relying on unsafe-sysctl kubelet
  # config or compose sysctls.
  [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] \
    || echo 1 > /proc/sys/net/ipv4/ip_forward
  local rule=(-s "$OVPN_SUBNET/$OVPN_NETMASK" -o eth0 -j MASQUERADE)
  iptables -t nat -C POSTROUTING "${rule[@]}" 2>/dev/null \
    || iptables -t nat -A POSTROUTING "${rule[@]}"
}

genclient() {
  local name="${1:?usage: genclient <name>}"
  if [ ! -f "$PKI_DIR/issued/$name.crt" ]; then
    "$EASYRSA" build-client-full "$name" nopass >&2
  fi
  cat <<EOF
client
dev tun
proto udp
remote $OVPN_REMOTE
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
data-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256
# Split tunnel: refuse any full-tunnel redirect, so only the pushed routes go
# through the VPN and the client keeps its own default gateway. (Honoured by
# the openvpn CLI; NetworkManager sets its own default route independently —
# there you also need ipv4.never-default yes.)
pull-filter ignore "redirect-gateway"
verb 3
<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>
<cert>
$(openssl x509 -in "$PKI_DIR/issued/$name.crt")
</cert>
<key>
$(cat "$PKI_DIR/private/$name.key")
</key>
<tls-crypt>
$(cat "$OVPN_DIR/ta.key")
</tls-crypt>
EOF
}

revoke() {
  local name="${1:?usage: revoke <name>}"
  "$EASYRSA" revoke "$name" >&2
  "$EASYRSA" gen-crl >&2
  cp "$PKI_DIR/crl.pem" "$OVPN_DIR/crl.pem"
  grep -q '^crl-verify' "$OVPN_DIR/server.conf" \
    || echo "crl-verify $OVPN_DIR/crl.pem" >> "$OVPN_DIR/server.conf"
  echo ">> $name revoked; restart the openvpn container to apply" >&2
}

case "${1:-server}" in
  genclient) shift; genclient "$@" ;;
  revoke)    shift; revoke "$@" ;;
  server)
    mkdir -p "$OVPN_DIR"
    init_pki
    write_server_conf
    write_dnsmasq_conf
    setup_nat
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
    dnsmasq
    exec openvpn --config "$OVPN_DIR/server.conf"
    ;;
  *)
    echo "unknown command: $1" >&2
    exit 1
    ;;
esac
