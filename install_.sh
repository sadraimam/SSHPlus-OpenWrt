#!/bin/sh

set -e

echo "[1/7] Installing packages..."
apk update
apk add hev-socks5-tunnel sshpass ca-certificates

echo "[2/7] Creating SSH SOCKS tunnel service..."

cat >/etc/init.d/ssh-socks <<'EOF'
#!/bin/sh /etc/rc.common

START=90
STOP=10

HOST="136.244.67.223"
USER="sadra"
PASS="sadra"
PORT="8089"

start() {
    echo "Starting SSH SOCKS tunnel..."

    sshpass -p "$PASS" ssh \
        -N \
        -D 127.0.0.1:$PORT \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        $USER@$HOST &
}

stop() {
    killall ssh 2>/dev/null || true
}
EOF

chmod +x /etc/init.d/ssh-socks
/etc/init.d/ssh-socks enable

echo "[3/7] Configuring hev-socks5-tunnel..."

cat >/etc/hev-socks5-tunnel/main.yml <<'EOF'
tunnel:
  name: tun0
  mtu: 1500
  ipv4: 198.18.0.1

socks5:
  address: 127.0.0.1
  port: 8089
  udp: 'tcp'

misc:
  log-level: warn
  log-file: stderr
EOF

echo "[4/7] Enabling hev-socks5-tunnel service..."
uci set hev-socks5-tunnel.config.enabled='1'
uci commit hev-socks5-tunnel
/etc/init.d/hev-socks5-tunnel enable

echo "[5/7] Starting services..."
/etc/init.d/ssh-socks start
sleep 5
/etc/init.d/hev-socks5-tunnel start

echo "[6/7] Checking tunnel..."

sleep 3
netstat -lnpt | grep 8089 || echo "SSH SOCKS NOT UP"
ip addr show tun0 || echo "TUN interface not ready yet"

echo "[7/7] Test internet via tunnel:"
curl --socks5-hostname 127.0.0.1:8089 https://api.ipify.org || true

echo "DONE"
