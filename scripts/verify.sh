#!/usr/bin/env bash
# Проверка минимального baseline. Печатает PASS/FAIL, код выхода 1 при провалах.
#
# Использование:
#   sudo ./verify.sh [LAN_IFACE] [EXPECTED_PUBLIC_IP]

LAN_IFACE=${1:-$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')}
EXPECTED_IP=${2:-}
PASS=0; FAIL=0; WARN=0

ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf 'WARN  %s\n' "$1"; WARN=$((WARN+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# Сеть
if [[ -n "$LAN_IFACE" ]] && ip -4 -o addr show dev "$LAN_IFACE" 2>/dev/null | grep -q "inet "; then
  ok "адрес на $LAN_IFACE"
else
  bad "нет IPv4 на интерфейсе ${LAN_IFACE:-<не определён>}"
fi

if have ethtool && [[ -n "$LAN_IFACE" ]] && ethtool "$LAN_IFACE" 2>/dev/null | grep -q "Speed: 1000Mb/s"; then
  ok "линк 1000Mb/s"
elif have ethtool && [[ -n "$LAN_IFACE" ]]; then
  warn "линк не 1000Mb/s (кабель/порт)"
fi

GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
if [[ -n "$GW" ]] && ping -c 2 -W 2 "$GW" >/dev/null 2>&1; then
  ok "ping шлюза $GW"
else
  bad "шлюз не пингуется"
fi

if getent hosts example.com >/dev/null 2>&1; then ok "DNS резолвит"; else bad "DNS не резолвит"; fi

PUB=$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
if [[ -n "$EXPECTED_IP" ]]; then
  [[ "$PUB" == "$EXPECTED_IP" ]] && ok "внешний IP $PUB" || bad "внешний IP $PUB (ожидался $EXPECTED_IP)"
elif [[ -n "$PUB" ]]; then
  ok "внешний IP $PUB"
else
  bad "не удалось получить внешний IP"
fi

# Система
if have systemctl; then
  if [[ -z "$(systemctl --failed --no-legend --plain 2>/dev/null | head -1)" ]]; then
    ok "нет упавших юнитов"
  else
    bad "есть упавшие юниты: $(systemctl --failed --no-legend --plain | head -3 | tr '\n' ' ')"
  fi
else
  warn "systemctl недоступен — юниты не проверены"
fi

if have sshd && sshd -T 2>/dev/null | grep -q '^passwordauthentication no'; then
  ok "SSH: вход по паролю выключен"
else
  warn "SSH: пароль/конфиг не проверены"
fi

if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then ok "UFW активен"; else warn "UFW не активен"; fi

if have systemctl && systemctl is-active --quiet fail2ban 2>/dev/null; then ok "fail2ban активен"; else warn "fail2ban не активен"; fi

if have timedatectl && timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then ok "время синхронизировано"; else warn "NTP не синхронизирован"; fi

USE=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$USE" ]] && (( USE < 90 )); then ok "диск занят ${USE}%"; else bad "диск занят ${USE}%"; fi

MEM=$(free -m | awk '/^Mem:/ {printf "%d", $7/$2*100}')
if (( MEM > 10 )); then ok "свободная память ${MEM}%"; else warn "мало свободной памяти (${MEM}%)"; fi

if have docker && docker info >/dev/null 2>&1; then ok "Docker работает"; fi
if have systemctl && systemctl is-active --quiet caddy 2>/dev/null; then ok "Caddy работает"; fi
if have ethtool && [[ -n "$LAN_IFACE" ]] && ethtool "$LAN_IFACE" 2>/dev/null | grep -q "Wake-on: g"; then ok "Wake-on-LAN включён"; fi

echo
echo "Итого: PASS=$PASS FAIL=$FAIL WARN=$WARN"
[[ $FAIL -eq 0 ]]
