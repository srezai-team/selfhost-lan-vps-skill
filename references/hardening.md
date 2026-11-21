# Минимальный защищённый baseline

Каждый пункт: зачем → команда → как проверить (PASS-критерий). Выполнять по порядку; после каждого блока — проверка, чтобы не потерять доступ.

## 1. SSH: только ключи

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 4
LoginGraceTime 20
ClientAliveInterval 60
ClientAliveCountMax 3
AllowUsers <USER> <AGENT_USER>
CONF
sudo sshd -t && sudo systemctl reload ssh
```

**Проверка:** с другой машины `ssh -o PreferredAuthentications=password <USER>@<IP>` → `Permission denied (publickey)`. Ключи в `~/.ssh/authorized_keys` с правами `600`, каталог `.ssh` — `700`.

## 2. Пользователи и sudo

Отдельный пользователь для автоматизации (`<AGENT_USER>`) + человек-администратор; root напрямую не используется. Если нужен sudo без пароля для автоматизации — только через отдельный файл `/etc/sudoers.d/90-automation` и только для нужных команд.

**Проверка:** `sudo -l -U <AGENT_USER>` показывает ровно ожидаемое.

## 3. UFW: входящие закрыты

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <LAN_CIDR> to any port 22 proto tcp
sudo ufw enable
sudo ufw status numbered
```

Порты сервисов открываются осознанно (`80/443` — только если сервис публикуется). Docker обходит ufw: публикуй контейнеры на `127.0.0.1:<port>` и проксируй через Caddy/nginx, либо добавляй правила в цепочку `DOCKER-USER`.

**Проверка:** с другой машины вне LAN порт 22 недоступен; из LAN — доступен.

## 4. fail2ban

```bash
sudo apt-get install -y fail2ban
sudo tee /etc/fail2ban/jail.local >/dev/null <<'CONF'
[DEFAULT]
bantime.increment = true
findtime = 10m
maxretry = 4
bantime = 1h

[sshd]
enabled = true
CONF
sudo systemctl enable --now fail2ban
```

**Проверка:** `sudo fail2ban-client status sshd` — jail активен, счётчик виден.

## 5. Обновления безопасности

```bash
sudo apt-get install -y unattended-upgrades needrestart
sudo dpkg-reconfigure -plow unattended-upgrades   # включить автообновления
```

**Проверка:** `sudo unattended-upgrade --dry-run -d | tail -5` проходит без ошибок; `systemctl status apt-daily-upgrade.timer` активен.

## 6. Время и NTP

```bash
timedatectl set-timezone <TZ>
timedatectl set-ntp true
```

**Проверка:** `timedatectl` → `System clock synchronized: yes`, `NTP service: active`.

## 7. sysctl

```bash
sudo tee /etc/sysctl.d/99-server.conf >/dev/null <<'CONF'
vm.swappiness = 10
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
CONF
sudo sysctl --system
```

**Проверка:** `sysctl vm.swappiness net.ipv4.tcp_syncookies` отдаёт заданные значения.

## 8. Логи

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\n' | sudo tee /etc/systemd/journald.conf.d/limits.conf
sudo systemctl restart systemd-journald
```

**Проверка:** `journalctl --disk-usage` меньше 500 МБ.

## 9. Docker

```bash
sudo apt-get install -y docker.io docker-compose-v2
sudo tee /etc/docker/daemon.json >/dev/null <<'CONF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
CONF
sudo systemctl restart docker
```

Каталог проектов: `/opt/stacks` (владелец — человек), compose-файлы рядом. В compose: `restart: unless-stopped`, healthcheck, порты только `127.0.0.1:<port>`.

**Проверка:** `docker info | grep -i "logging driver"`; `docker compose version`.

## 10. Бэкапы

```bash
sudo apt-get install -y restic
# инициализация репозитория на внешнем носителе/NAS/облаке
restic -r <REPO> init
```

Скрипт + systemd timer ежедневно: `/etc/backup.d/`; исключить `/proc`, `/sys`, `/var/lib/docker/overlay2` (тома — отдельно). Пароль репозитория — в менеджере паролей владельца.

**Проверка:** восстановить один файл в `/tmp` и сравнить `sha256sum`. Бэкап без проверки восстановления не считается.

## 11. Мониторинг

Heartbeat: `curl -fsS --max-time 5 <PUSH_URL>` каждые 60 с (systemd timer) + health-скрипт (диск, память, температура, load) раз в 5 минут. Уведомления — в мессенджер владельца.

**Проверка:** тестовое событие «DOWN» и «UP» дошли до владельца.

## 12. BIOS и Wake-on-LAN

В BIOS: `Restore AC Power Loss`/`State After G3` → **Power On**; `Wake on LAN` → **Enabled**; `ErP` → **Disabled**. Если iGPU забирает оперативку (`UMA Frame Buffer Size`/`DVMT`) — уменьшить до 512 МБ.

```bash
sudo apt-get install -y ethtool
sudo ethtool -s <LAN_IFACE> wol g
# юнит на автозагрузку
sudo tee /etc/systemd/system/wol-enable.service >/dev/null <<'CONF'
[Unit]
Description=Enable Wake-on-LAN (magic packet)
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s <LAN_IFACE> wol g
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
CONF
sudo systemctl enable --now wol-enable.service
```

**Проверка:** `sudo ethtool <LAN_IFACE> | grep Wake-on` → `g`; выключить машину и разбудить из LAN (`wakeonlan <MAC>`).

## 13. Диск

`smartctl -a` (smartmontools) для SSD; `sudo fstrim -av` для TRIM; если корень на LVM — снапшоты доступны (`lvcreate -s`), проверить свободное место в VG. Swap — файл/раздел разумного размера, но не вместо RAM.

**Проверка:** `df -h /`, `sudo vgs`, `sudo smartctl -H <DEV>` → PASSED.
