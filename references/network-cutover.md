# Переключение сети без потери доступа

Цель: сервер переезжает с Wi-Fi на кабель, сохраняя один рабочий путь в интернет и возможность отката. Применяется и к обратному случаю.

## Правила

1. **Один IP — один интерфейс.** Один и тот же адрес на `enpXsY` и `wlpXsY` даёт дубль и рвёт маршрутизацию/туннели.
2. **Кабель — основной, Wi-Fi — резерв** на отдельном адресе с `metric 700` (кабель 100). Если кабель отвалится, default-route уйдёт на Wi-Fi сам.
3. **Адрес вне DHCP-пула** или резервация по MAC в роутере. Пул видно в админке роутера; если доступа нет — бери адрес из верхней части подсети и проверь конфликт (`arping -D`, `ping` до применения).
4. **Страховка обязательна.** Перед `apply` — бэкап конфигов и отложенный откат.
5. **Применяй detached.** Смена IP рвёт SSH; команда должна пережить разрыв.

## Рендерер

```bash
systemctl is-active systemd-networkd NetworkManager
ls -l /etc/netplan/ && sudo netplan get
```

## Шаблон netplan (systemd-networkd)

`/etc/netplan/00-lan.yaml`:

```yaml
network:
  version: 2
  ethernets:
    <LAN_IFACE>:
      match:
        macaddress: "<LAN_MAC>"
      set-name: <LAN_IFACE>
      dhcp4: false
      optional: false
      addresses: [<STATIC_IP>/24]
      routes:
        - to: default
          via: <GATEWAY>
          metric: 100
      nameservers:
        addresses: [<GATEWAY>, 1.1.1.1]
```

`/etc/netplan/60-wifi.yaml` — резерв:

```yaml
network:
  version: 2
  wifis:
    <WIFI_IFACE>:
      dhcp4: false
      optional: true
      addresses: [<RESERVE_IP>/24]
      routes:
        - to: default
          via: <GATEWAY>
          metric: 700
      access-points:
        "<SSID>":
          password: "<PSK>"
```

Перед выдачей разным интерфейсам разных адресов одной подсети приглуши ARP-flux:

```bash
sudo tee /etc/sysctl.d/99-dual-home.conf >/dev/null <<'CONF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.default.arp_announce = 2
CONF
sudo sysctl --system
```

## NetworkManager вместо networkd

```bash
nmcli -t -f NAME,DEVICE con show
sudo nmcli con mod "<WIRED_PROFILE>" ipv4.method manual \
  ipv4.addresses <STATIC_IP>/24 ipv4.gateway <GATEWAY> ipv4.dns "<GATEWAY>,1.1.1.1"
sudo nmcli con mod "<WIFI_PROFILE>" ipv4.route-metric 700
sudo nmcli con up "<WIRED_PROFILE>"
```

## Страховка и применение

```bash
sudo cp -a /etc/netplan /root/netplan-backup-$(date +%F)
# откат через 180 с, если что-то пойдёт не так
sudo systemd-run --on-active=180 --unit=netplan-guard /bin/bash -c \
  'cp -a /root/netplan-backup-$(date +%F)/. /etc/netplan/ && /usr/sbin/netplan apply && systemctl restart <TUNNEL_UNIT> 2>/dev/null'
sudo /usr/sbin/netplan generate && sudo systemd-run --unit=netplan-apply --collect /usr/sbin/netplan apply
```

Готовый сценарий с проверками — [`../scripts/netplan-cutover.sh`](../scripts/netplan-cutover.sh). Переменная `<TUNNEL_UNIT>` — сервис обратного туннеля, если он используется для доступа агента.

## Проверки после применения

```bash
ip -4 -br a                            # адрес на кабельном интерфейсе
ip route | grep default                # ровно один основной маршрут (второй — с большей метрикой)
ip route get 1.1.1.1                   # должен идти через кабельный интерфейс
ping -c 3 <GATEWAY>                    # 0% потерь, доли миллисекунды
resolvectl status | grep -A2 "DNS Servers"
curl -s https://ifconfig.me; echo      # ожидаемый внешний IP
systemctl --failed --no-legend         # пусто
```

Затем **сними страховку**: `sudo systemctl stop netplan-guard.timer && sudo systemctl reset-failed netplan-guard.timer`.

## Измерение скорости (для отчёта)

```bash
curl -sL --max-time 20 -o /dev/null -w '%{size_download} %{time_total}\n' '<BIG_FILE_URL>'
# Мбит/с = size_download * 8 / time_total / 1e6
ping -c 30 -i 0.2 -q <GATEWAY> | tail -2   # задержка и джиттер
```

Сравнивай кабель и Wi-Fi на одном и том же URL: интернет может упираться в тариф, тогда разница видна в задержке/джиттере, а не в скорости.

## Откат

```bash
sudo cp -a /root/netplan-backup-<ДАТА>/. /etc/netplan/ && sudo /usr/sbin/netplan apply
```

## Если доступ идёт через обратный туннель

Смена IP рвёт сеанс, а старый сеанс на удалённой стороне ещё держит порт (симптом: `remote port forwarding failed for listen port <PORT>`, рестарты каждые 10 с). Порядок: остановить туннель → применить сеть → запустить туннель. Долгосрочно — на принимающей стороне `ClientAliveInterval 15` + `ClientAliveCountMax 2` в `Match`-блоке пользователя туннеля.
