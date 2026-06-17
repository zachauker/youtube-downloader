#!/bin/sh
# Connects to Private Internet Access via WireGuard and applies an iptables kill switch.
# Required env vars: PIA_USER, PIA_PASS
# Optional env vars: PIA_REGION (default: us_silicon_valley), LAN_NETWORK (default: 192.168.1.0/24)
set -e

PIA_REGION="${PIA_REGION:-us_silicon_valley}"
LAN_NETWORK="${LAN_NETWORK:-192.168.1.0/24}"
WG_PORT=1337

log() { echo "[VPN] $*"; }
die() { echo "[VPN] ERROR: $*" >&2; exit 1; }

[ -n "${PIA_USER:-}" ] || die "PIA_USER is not set"
[ -n "${PIA_PASS:-}" ] || die "PIA_PASS is not set"

# ── 1. Authenticate ───────────────────────────────────────────────────────────
log "Authenticating with PIA..."
TOKEN_RESP=$(curl -sf -m 15 -u "${PIA_USER}:${PIA_PASS}" \
    "https://privateinternetaccess.com/gtoken/generateToken") \
    || die "Could not reach PIA auth endpoint"

TOKEN=$(echo "$TOKEN_RESP" | jq -r '.token // empty')
[ -n "$TOKEN" ] || die "Auth failed — check PIA_USER / PIA_PASS. Response: $TOKEN_RESP"
log "Authenticated."

# ── 2. Pick a server ──────────────────────────────────────────────────────────
log "Fetching server list..."
SERVERS=$(curl -sf -m 20 "https://serverlist.piaservers.net/vpninfo/servers/v6" \
    | head -1) || die "Could not fetch PIA server list"

WG_HOST=$(echo "$SERVERS" | jq -r ".regions[] | select(.id == \"${PIA_REGION}\") | .servers.wg[0].ip // empty")
WG_CN=$(echo   "$SERVERS" | jq -r ".regions[] | select(.id == \"${PIA_REGION}\") | .servers.wg[0].cn // empty")

if [ -z "$WG_HOST" ]; then
    log "Region '${PIA_REGION}' not found. Available regions:"
    echo "$SERVERS" | jq -r '.regions[].id' | sort | sed 's/^/    /'
    die "Set PIA_REGION to one of the values above"
fi
log "Server: ${PIA_REGION} → ${WG_HOST}"

# ── 3. Generate WireGuard keypair ─────────────────────────────────────────────
WG_PRIV=$(wg genkey)
WG_PUB=$(echo "$WG_PRIV" | wg pubkey)

# ── 4. Register key with the PIA server ──────────────────────────────────────
log "Registering WireGuard key with PIA server..."
REGISTER=$(curl -sf -m 15 -G \
    --connect-to "${WG_CN}::${WG_HOST}:" \
    --cacert /etc/ssl/certs/ca-certificates.crt \
    --data-urlencode "pt=${TOKEN}" \
    --data-urlencode "pubkey=${WG_PUB}" \
    "https://${WG_CN}:${WG_PORT}/addKey") || die "Key registration request failed"

STATUS=$(echo "$REGISTER" | jq -r '.status // empty')
[ "$STATUS" = "OK" ] || die "Key registration rejected: $REGISTER"

SERVER_PUB=$(echo "$REGISTER" | jq -r '.server_pub_key')
CLIENT_IP=$(echo  "$REGISTER" | jq -r '.peer_ip')
DNS_IP=$(echo     "$REGISTER" | jq -r '.dns_servers[0]')
log "Assigned tunnel IP: ${CLIENT_IP}  DNS: ${DNS_IP}"

# ── 5. Save pre-VPN gateway so we can route the WG endpoint through it ────────
DEFAULT_GW=$(ip route show default | awk 'NR==1{print $3}')
DEFAULT_IF=$(ip route show default | awk 'NR==1{print $5}')
[ -n "$DEFAULT_GW" ] || die "No default gateway found"

# ── 6. Create wg0 interface ───────────────────────────────────────────────────
log "Configuring wg0..."
ip link add wg0 type wireguard 2>/dev/null || ip link set wg0 down
ip addr flush dev wg0 2>/dev/null || true
ip addr add "${CLIENT_IP}/32" dev wg0

# Write config to temp file (avoids shell-escaping the private key)
WG_CONF=$(mktemp)
cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${WG_PRIV}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${WG_HOST}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
wg setconf wg0 "$WG_CONF"
rm -f "$WG_CONF"

ip link set wg0 up

# ── 7. Routing ────────────────────────────────────────────────────────────────
# Keep a specific route to the VPN endpoint via the real gateway
# (so WireGuard handshakes can reach the server before the tunnel is up)
ip route replace "${WG_HOST}/32" via "$DEFAULT_GW" dev "$DEFAULT_IF"

# Route everything else through the tunnel
ip route del default 2>/dev/null || true
ip route add default dev wg0

# Use PIA's DNS
echo "nameserver ${DNS_IP}" > /etc/resolv.conf

# ── 8. Kill switch ────────────────────────────────────────────────────────────
log "Applying kill switch (LAN passthrough: ${LAN_NETWORK})..."
iptables -F
iptables -X

# Default: drop everything
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# Loopback
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related (replies to initiated connections)
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# LAN — keeps the WebUI reachable on the local network
iptables -A INPUT  -s "${LAN_NETWORK}" -j ACCEPT
iptables -A OUTPUT -d "${LAN_NETWORK}" -j ACCEPT

# WireGuard handshake UDP to the VPN server (goes via eth0, not wg0)
iptables -A OUTPUT -d "${WG_HOST}/32" -p udp --dport "${WG_PORT}" -j ACCEPT
iptables -A INPUT  -s "${WG_HOST}/32" -p udp --sport "${WG_PORT}" -j ACCEPT

# All traffic through the VPN tunnel
iptables -A INPUT  -i wg0 -j ACCEPT
iptables -A OUTPUT -o wg0 -j ACCEPT

log "Kill switch active — all non-VPN, non-LAN traffic is blocked."
log "Connected to PIA (${PIA_REGION}). Tunnel IP: ${CLIENT_IP}"
