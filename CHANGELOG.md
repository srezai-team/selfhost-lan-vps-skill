# Changelog

All notable changes to this skill are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: [SemVer](https://semver.org/).

## [0.1.0] — 2026-11-21

### Added

- `SKILL.md` — five phases with explicit completion criteria: discovery, cable cutover, network switch, hardening, external access, handover.
- `references/client-protocol.md` — owner questionnaire, physical steps, ISP support call script with a decision table for bridge/DMZ/DHCP/PPPoE/CGNAT answers, and a plain-language glossary.
- `references/network-cutover.md` — dual-homing rules (one address per interface, metric 700 fallback), ARP-flux sysctls, netplan and NetworkManager templates, timestamped backup + timed rollback, detached apply, verification and speed comparison.
- `references/hardening.md` — 13 hardening groups with PASS checks: SSH keys only, UFW, fail2ban, unattended upgrades, NTP, sysctl, journald limits, Docker log limits, backups with restore test, heartbeat monitoring, BIOS power-on/Wake-on-LAN, disk health.
- `references/external-access.md` — NAT topology decision from the router's WAN address, bridge/DMZ requests, port forwarding (generic table plus embedded-Linux nvram example), DNS, Caddy + Let's Encrypt, external verification, VPS + reverse-tunnel fallback.
- `references/pitfalls.md` — 14 entries in `symptom → cause → fix` form, including router login lockout, firewall restart losing NAT, reverse-tunnel port lingering and Docker bypassing UFW.
- `references/handover-docs.md` — templates for STATUS / HANDOFF / HISTORY / NEXT-STEPS and the six-line owner summary.
- `scripts/netplan-cutover.sh` — static LAN address with duplicate-address checks, backup, 180-second auto-rollback and detached apply.
- `scripts/verify.sh` — PASS/FAIL baseline verification with non-zero exit code, degrades gracefully without systemd.
- `examples/wive-ng-port-forwarding.md` — worked example on an embedded Linux router.
