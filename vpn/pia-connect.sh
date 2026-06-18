#!/bin/sh
# Connects to Private Internet Access via WireGuard and applies an iptables kill switch.
# Required env vars: PIA_USER, PIA_PASS
# Optional env vars: PIA_REGION (default: us_silicon_valley)
set -e

PIA_REGION="${PIA_REGION:-us_silicon_valley}"
WEBUI_PORT="${WEBUI_PORT:-8090}"
WG_PORT=1337
PIA_CACERT="/etc/pia/ca.rsa.4096.crt"

log()  { echo "[VPN] $*"; }
die()  { echo "[VPN] FATAL: $*" >&2; exit 1; }
warn() { echo "[VPN] WARN:  $*" >&2; }

[ -n "${PIA_USER:-}" ] || die "PIA_USER is not set — set it in docker-compose.yml"
[ -n "${PIA_PASS:-}" ] || die "PIA_PASS is not set — set it in docker-compose.yml"

# ── 1. Authenticate ───────────────────────────────────────────────────────────
log "Authenticating with PIA..."
TOKEN_RESP=$(curl -sf -m 15 -u "${PIA_USER}:${PIA_PASS}" \
    "https://privateinternetaccess.com/gtoken/generateToken") \
    || die "Auth request failed — is the internet reachable?"

TOKEN=$(echo "$TOKEN_RESP" | jq -r '.token // empty')
[ -n "$TOKEN" ] || die "Auth failed — check PIA_USER/PIA_PASS. Server said: $TOKEN_RESP"
log "Authenticated."

# ── 2. Pick a server ──────────────────────────────────────────────────────────
log "Fetching PIA server list..."
SERVERS=$(curl -sf -m 20 "https://serverlist.piaservers.net/vpninfo/servers/v6" \
    | head -1) || die "Could not fetch server list"

WG_HOST=$(echo "$SERVERS" | jq -r ".regions[] | select(.id == \"${PIA_REGION}\") | .servers.wg[0].ip // empty")
WG_CN=$(echo   "$SERVERS" | jq -r ".regions[] | select(.id == \"${PIA_REGION}\") | .servers.wg[0].cn // empty")

if [ -z "$WG_HOST" ]; then
    log "Region '${PIA_REGION}' not found. Valid options:"
    echo "$SERVERS" | jq -r '.regions[].id' | sort | sed 's/^/    /'
    die "Set PIA_REGION to one of the values above"
fi
log "Region: ${PIA_REGION} → ${WG_HOST}"

# ── 3. Generate WireGuard keypair ─────────────────────────────────────────────
WG_PRIV=$(wg genkey)
WG_PUB=$(echo "$WG_PRIV" | wg pubkey)

# ── 4. Register key with PIA ──────────────────────────────────────────────────
# Test TCP reachability first so the error is clear if port 1337 is firewalled.
log "Testing reachability of ${WG_HOST}:${WG_PORT}..."
if ! nc -z -w 5 "${WG_HOST}" "${WG_PORT}" 2>/dev/null; then
    die "Cannot reach ${WG_HOST}:${WG_PORT} — TCP port ${WG_PORT} appears blocked.\n       Check that your network/firewall allows outbound TCP to that port."
fi
log "Port ${WG_PORT} reachable."

# Uses PIA's own CA cert — the system bundle does not include their CA.
log "Registering WireGuard key..."
REGISTER=$(curl -sS --show-error -m 15 -G \
    --connect-to "${WG_CN}::${WG_HOST}:" \
    --cacert "${PIA_CACERT}" \
    --data-urlencode "pt=${TOKEN}" \
    --data-urlencode "pubkey=${WG_PUB}" \
    "https://${WG_CN}:${WG_PORT}/addKey" 2>&1) || die "Key registration curl failed:\n       ${REGISTER}"

STATUS=$(echo "$REGISTER" | jq -r '.status // empty')
[ "$STATUS" = "OK" ] || die "Key registration rejected by server: ${REGISTER}"

SERVER_PUB=$(echo "$REGISTER" | jq -r '.server_key')
CLIENT_IP=$(echo  "$REGISTER" | jq -r '.peer_ip')
DNS_IP=$(echo     "$REGISTER" | jq -r '.dns_servers[0]')

[ -n "$SERVER_PUB" ] && [ "$SERVER_PUB" != "null" ] || die "server_key missing from PIA response: ${REGISTER}"
[ -n "$CLIENT_IP"  ] && [ "$CLIENT_IP"  != "null" ] || die "peer_ip missing from PIA response: ${REGISTER}"
[ -n "$DNS_IP"     ] && [ "$DNS_IP"     != "null" ] || die "dns_servers missing from PIA response: ${REGISTER}"

log "Tunnel IP: ${CLIENT_IP}  DNS: ${DNS_IP}"

# ── 5. Record default gateway before touching routes ─────────────────────────
DEFAULT_GW=$(ip route show default | awk 'NR==1{print $3}')
DEFAULT_IF=$(ip route show default | awk 'NR==1{print $5}')
[ -n "$DEFAULT_GW" ] || die "No default gateway — Docker network issue?"
log "Existing default gateway: ${DEFAULT_GW} via ${DEFAULT_IF}"

# ── 6. Create and configure wg0 ──────────────────────────────────────────────
log "Configuring WireGuard interface..."
ip link add wg0 type wireguard 2>/dev/null || ip link set wg0 down
ip addr flush dev wg0 2>/dev/null || true
ip addr add "${CLIENT_IP}/32" dev wg0

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
# Pin the VPN endpoint to the real gateway so WireGuard handshakes use eth0
ip route replace "${WG_HOST}/32" via "$DEFAULT_GW" dev "$DEFAULT_IF"

# Route all RFC1918 ranges back via eth0 (the Docker bridge gateway).
# Without this, nginx responses to LAN clients (e.g. a browser at 192.168.x.x)
# hit the default route (wg0), get encrypted and sent into the VPN tunnel, and
# the VPN server can't route them back to your LAN — causing a WebUI timeout.
# Internet traffic (non-RFC1918) still uses the default wg0 route below.
ip route replace 10.0.0.0/8     via "$DEFAULT_GW" dev "$DEFAULT_IF"
ip route replace 192.168.0.0/16 via "$DEFAULT_GW" dev "$DEFAULT_IF"
# 172.16.0.0/12 is already covered by the directly-connected Docker network route

# All internet traffic goes through the VPN tunnel
ip route del default 2>/dev/null || true
ip route add default dev wg0

# Use PIA's DNS
echo "nameserver ${DNS_IP}" > /etc/resolv.conf

# ── 8. Kill switch (OUTPUT-only) ─────────────────────────────────────────────
# We only lock down OUTPUT, leaving INPUT untouched.
# Blocking INPUT causes Docker's port mapping to stop working for the WebUI,
# regardless of --dport rules, due to how the bridge NAT rewrites packet headers.
#
# The kill switch still works: if wg0 drops, the default route disappears and
# any download attempt fails — plus our OUTPUT DROP rule below blocks internet
# traffic that hasn't gone through the tunnel.
log "Applying kill switch..."

iptables -F OUTPUT

# Allow loopback (nginx ↔ uvicorn)
iptables -A OUTPUT -o lo -j ACCEPT

# Allow all outbound through VPN tunnel
iptables -A OUTPUT -o wg0 -j ACCEPT

# Allow WireGuard handshake UDP to the VPN endpoint (goes via eth0)
iptables -A OUTPUT -d "${WG_HOST}/32" -p udp --dport "${WG_PORT}" -j ACCEPT

# Allow outbound to RFC1918 private ranges (LAN, Docker bridge, oakwood_proxy)
iptables -A OUTPUT -d 10.0.0.0/8     -j ACCEPT
iptables -A OUTPUT -d 172.16.0.0/12  -j ACCEPT
iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT

# Block everything else outbound — the kill switch
iptables -A OUTPUT -j DROP

log "Kill switch active."
log "Connected to PIA (${PIA_REGION}). All downloads tunnel through ${CLIENT_IP}."
