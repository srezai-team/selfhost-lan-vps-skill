#!/usr/bin/env bash
# Перевод сервера на статический адрес по кабельному интерфейсу с откатом.
#
# Использование:
#   sudo ./netplan-cutover.sh <LAN_IFACE> <LAN_MAC> <STATIC_IP/CIDR> <GATEWAY> [TUNNEL_UNIT]
#
# Пример:
#   sudo ./netplan-cutover.sh enp2s0 68:1d:ef:64:d2:43 192.168.1.120/24 192.168.1.1 ssh-tunnel.service
#
# Что делает: бэкап /etc/netplan → пишет 00-lan.yaml → netplan generate →
# страховка (откат через 180 с) → применяет detached → печатает проверки.
# Подтверждение: sudo systemctl stop netplan-guard.timer

set -euo pipefail

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ОШИБКА: нужен root (sudo)" >&2; exit 1; }
[[ $# -ge 4 ]] || usage

LAN_IFACE=$1
LAN_MAC=$2
ADDR=$3          # 192.168.1.120/24
GW=$4
TUNNEL_UNIT=${5:-}
IP_ONLY=${ADDR%/*}
TS=$(date +%F-%H%M%S)
BACKUP="/root/netplan-backup-$TS"

command -v netplan >/dev/null || { echo "ОШИБКА: нет netplan (не Ubuntu?)" >&2; exit 1; }
ip link show "$LAN_IFACE" >/dev/null 2>&1 || { echo "ОШИБКА: нет интерфейса $LAN_IFACE" >&2; exit 1; }

# 1. Тот же адрес уже висит на другом интерфейсе?
if ip -4 -o addr show 2>/dev/null | grep -q " $ADDR "; then
  if ! ip -4 -o addr show dev "$LAN_IFACE" 2>/dev/null | grep -q " $ADDR "; then
    echo "ОШИБКА: $ADDR уже назначен другому интерфейсу." >&2
    echo "Сначала убери адрес оттуда (резерв должен быть на другом адресе)." >&2
    exit 1
  fi
fi

# 2. Адрес занят кем-то в сети?
if command -v arping >/dev/null 2>&1; then
  if ! arping -D -I "$LAN_IFACE" -c 2 "$IP_ONLY" >/dev/null 2>&1; then
    echo "ОШИБКА: $IP_ONLY отвечает в сети — похоже на конфликт адресов." >&2
    exit 1
  fi
fi

# 3. Тот же адрес в других netplan-файлах (дубль)?
if grep -rqs "addresses:.*$IP_ONLY" /etc/netplan/*.yaml 2>/dev/null; then
  echo "ВНИМАНИЕ: $IP_ONLY встречается в других netplan-файлах — их нужно перевести на другой адрес." >&2
fi

# 4. Бэкап и конфиг
mkdir -p "$BACKUP"
cp -a /etc/netplan/. "$BACKUP"/
cat > /etc/netplan/00-lan.yaml <<CONF
network:
  version: 2
  ethernets:
    $LAN_IFACE:
      match:
        macaddress: "$LAN_MAC"
      set-name: $LAN_IFACE
      dhcp4: false
      optional: false
      addresses: [$ADDR]
      routes:
        - to: default
          via: $GW
          metric: 100
      nameservers:
        addresses: [$GW, 1.1.1.1]
CONF
chmod 600 /etc/netplan/*.yaml
netplan generate
echo "конфиг валиден, бэкап: $BACKUP"

# 5. Страховка: откат через 180 с
systemctl stop netplan-guard.timer 2>/dev/null || true
systemctl reset-failed netplan-guard.service netplan-guard.timer 2>/dev/null || true
RESTORE_EXTRA=""
[[ -n "$TUNNEL_UNIT" ]] && RESTORE_EXTRA="systemctl restart $TUNNEL_UNIT"
systemd-run --on-active=180 --unit=netplan-guard /bin/bash -c \
  "cp -a $BACKUP/. /etc/netplan/ && /usr/sbin/netplan apply; $RESTORE_EXTRA" >/dev/null
echo "страховка взведена: откат через 180 с"

# 6. Применяем detached (смена IP рвёт SSH)
systemd-run --unit=netplan-apply --collect /usr/sbin/netplan apply >/dev/null
sleep 8

# 7. Проверки
echo "--- адреса ---"
ip -4 -br a | grep -v docker || true
echo "--- маршруты по умолчанию ---"
ip route | grep default || true
echo "--- маршрут до 1.1.1.1 ---"
ip route get 1.1.1.1 2>/dev/null || true
echo "--- ping шлюза ---"
ping -c 3 -W 2 "$GW" | tail -2 || true

cat <<'NEXT'

Дальше:
  1) проверь IP, маршрут, DNS, интернет и сервисы;
  2) если всё хорошо — подтверди:  sudo systemctl stop netplan-guard.timer
  3) если нет — подожди 3 минуты: страховка вернёт прошлый конфиг.
NEXT
