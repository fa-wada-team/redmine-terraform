#!/bin/bash
# NAT インスタンス初期化スクリプト
set -euxo pipefail

dnf install -y iptables-services

cat > /etc/sysctl.d/90-nat.conf <<'CONF'
net.ipv4.ip_forward = 1
CONF
sysctl --system

IFACE=$(ip route show default | awk '{print $5; exit}')
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
iptables -F FORWARD
iptables -P FORWARD ACCEPT
iptables-save > /etc/sysconfig/iptables

systemctl enable --now iptables
