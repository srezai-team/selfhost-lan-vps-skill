# Worked example: port forwarding on an embedded Linux router (Wive-NG style)

Some ISP-supplied routers run a Linux-based firmware with a web panel and an SSH/telnet CLI. When the panel is unhelpful (or locked after failed logins) and SSH works, port forwarding can be configured through the firmware's config system — **without restarting the firewall**, because a full restart may drop NAT and with it your own remote access.

Use this as an example of the shape, not as a universal recipe: names and formats differ per firmware.

## 0. What to confirm first

- Public IP is on **this** router (WAN interface), not on the provider's terminal. `traceroute` showing a private hop proves nothing.
- The server's address is pinned by a DHCP reservation, so the forwarding target cannot move.
- You have a second path to the router (console, local access) in case the change goes wrong.

## 1. Router facts

```bash
# from a machine on the LAN, with SSH access to the router
ssh Admin@192.168.1.1 'ifconfig | grep -E "^[a-z]|inet addr"; route -n'
```

Expect a WAN interface with the public address and a LAN bridge (e.g. `br0 192.168.1.1`). The forwarding rules must match traffic entering the **WAN** interface.

## 2. Config storage

Many of these firmwares keep configuration in `nvram` and generate the actual scripts from it:

```bash
nvram show 2860 | grep -iE 'forward|dhcp|dmz'   # keys
ls -la /etc/portforward*                        # generated scripts (may not exist yet)
```

## 3. Write the rules

Rule format for this firmware family (9 fields):

```
<iface>,<proto>,<src-port-from>,<src-port-to>,<dst-ip>,<dst-port-from>,<dst-port-to>,<nat-loopback>,<comment>
# proto: 1 = TCP, 2 = UDP, 3 = TCP+UDP
```

```bash
nvram_set 2860 PortForwardEnable 1
nvram_set 2860 PortForwardRules "WAN,1,80,80,192.168.1.120,80,80,0,web-80;WAN,1,443,443,192.168.1.120,443,443,0,web-443;"
```

DHCP reservation in the same store (format varies; here: `MAC IP` per entry, entries separated by `;`):

```bash
nvram_set 2860 dhcpStatic "68:1d:ef:64:d2:43 192.168.1.120"
```

## 4. Generate, inspect, apply only the delta

```bash
nvram_geniptablesrules 2860
cat /etc/portforward           # generated DNAT rules — inspect before running
cat /etc/portforward_access    # generated FORWARD ACCEPT rules

/etc/portforward <PUBLIC_IP>   # applies only the port-forward rules
/etc/portforward_access
```

Do **not** restart the whole firewall service here: it rebuilds the entire ruleset, and a mistake silently drops NAT — including the reverse tunnel you may be using to reach the server.

## 5. Verify

```bash
# on the router
iptables -t nat -L port_forward_pre -n

# from a host outside the home network (not from the LAN!)
curl -sI http://<PUBLIC_IP>/              # expect the service's response code
nc -zv <PUBLIC_IP> 80 443
```

If the external check fails while the rules look correct, the remaining candidates in order are: the provider blocks the ports, the service is not listening, the host firewall denies the port, or the public IP is actually behind another NAT.

## 6. Persistence

These changes live in the router's configuration store and its boot scripts regenerate the rules, so they survive reboots. After a firmware update, re-check both the nvram keys and the generated scripts.
