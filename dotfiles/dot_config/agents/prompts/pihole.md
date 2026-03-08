---
name: pihole-server-setup
description: Sets up a fully secure, configured, and functional Pi-Hole server.
---

# Pi-hole Server Setup

Read and follow all rules in `~/.config/agents/rules/`.
Invoke skills from `~/.config/agents/skills/` when the task matches their description.

## Context & Constraints

- Target: fresh Debian 12+ or Ubuntu 22.04+ VPS, public-facing, no prior hardening.
- Package manager: `apt` exclusively. No homebrew on the server.
- All scripts must be idempotent — detect current state before acting, safe to re-run.
- All scripts must follow the shell standards in `~/.config/agents/rules/06-shell.md`.
- All scripts must replicate the output pattern from `ph-test` (pass/fail/info/fix with ANSI colors, summary array, print_summary).
- User confirmation required before installing Pi-hole and Tailscale. Hardening runs without confirmation.
- Scripts live in `~/.local/bin/` (chezmoi prefix: `dotfiles/dot_local/bin/executable_*`).

## Existing Scripts

Read these first. Follow their conventions and patterns exactly.

| Script | Purpose |
|--------|---------|
| `ph-test` | Pi-hole + Unbound diagnostic suite: config syntax, service status, listening ports, DNS resolution, cache, DNSSEC, blocklist, stats, setup & security audit |
| `ts-test` | Tailscale diagnostic suite: service status, backend state, network, DNS, exit node, IP forwarding, peer connectivity |
| `ph-update` | System + Pi-hole + PADD updater |
| `ph-padd` / `ph-padd-unbound` | PADD dashboards (do not modify) |

## Scripts to Build

| Script | Purpose | Validates with |
|--------|---------|---------------|
| `ph-harden` | Server lockdown: SSH, firewall, fail2ban, unattended-upgrades, sysctl | `ph-harden-test` |
| `ph-harden-test` | Hardening validation test suite (mirrors `ph-test` structure) | — |
| `ph-install` | Install and configure Pi-hole + Unbound | `ph-test` |
| `ts-install` | Install and configure Tailscale | `ts-test` |
| `ph-setup` | Orchestrator: runs all phases, prompts for confirmation, produces final report | all of the above |

Build order matters — later scripts depend on earlier ones:

1. `ph-harden` + `ph-harden-test` (no dependencies, secures the exposed box first)
2. `ph-install` (depends on hardening: systemd-resolved disabled, firewall in place)
3. `ts-install` (depends on Pi-hole for DNS integration)
4. `ph-setup` (depends on all individual scripts existing)

---

## Script Specifications

### ph-harden

Server hardening script. Each step must detect current state and skip if already applied.

**SSH hardening:**
- Disable root login (`PermitRootLogin no`)
- Disable password auth (`PasswordAuthentication no`)
- Allow only key-based auth (`PubkeyAuthentication yes`)
- SSH port configurable (default: 22, accept as argument)
- Safety: test SSH in a new connection before closing the current session. Set up a cron job that restores `/etc/ssh/sshd_config` after 5 minutes unless a flag file is touched — prevents lockout.

**Firewall (ufw):**
```bash
sudo apt install ufw
sudo ufw allow <ssh-port>/tcp
# DNS and web admin restricted to Tailscale interface (added later by ts-install)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
```

**fail2ban:**
```bash
sudo apt install fail2ban
```
Create `/etc/fail2ban/jail.local` (never edit `jail.conf`):
```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
port     = <ssh-port>
backend  = systemd
maxretry = 3
```
Use `banaction = ufw` so fail2ban and ufw share the same firewall layer. Use `backend = systemd` since modern Debian/Ubuntu log to the journal.

**Automatic security updates:**
```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

**Disable systemd-resolved** (frees port 53 for Pi-hole):
```bash
sudo systemctl disable --now systemd-resolved
```
Set a static nameserver in `/etc/resolv.conf` temporarily (e.g., `nameserver 1.1.1.1`) until Pi-hole takes over.

**Kernel hardening sysctl** (write to `/etc/sysctl.d/99-hardening.conf`):
- `net.ipv4.conf.all.rp_filter = 1`
- `net.ipv4.conf.all.accept_redirects = 0`
- `net.ipv6.conf.all.accept_redirects = 0`
- `net.ipv4.conf.all.send_redirects = 0`
- `net.ipv4.conf.all.accept_source_route = 0`
- `net.ipv4.icmp_echo_ignore_broadcasts = 1`
- `net.core.rmem_max = 1048576` (for Unbound socket buffer)

### ph-harden-test

Mirrors `ph-test` structure: `pass()`/`fail()`/`info()`/`fix()` helpers, `SUMMARY_RESULTS` array, `print_summary()`.

Test each hardening measure:
- SSH: root login disabled, password auth disabled, correct port, sshd running
- ufw: active, default deny incoming, SSH port allowed
- fail2ban: running, sshd jail active, banaction is ufw
- unattended-upgrades: package installed, service enabled
- systemd-resolved: inactive and disabled
- sysctl: each hardening value matches expected

Every `fail` must include a copy/paste-ready `fix` command.

### ph-install

**Pi-hole unattended install:**

Pre-seed `/etc/pihole/setupVars.conf` before running the installer. Detect the primary interface and IP automatically.

```bash
sudo mkdir -p /etc/pihole
# Auto-detect interface and IP
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
IP_ADDR=$(ip -4 addr show "${IFACE}" | awk '/inet / {print $2; exit}')

sudo tee /etc/pihole/setupVars.conf > /dev/null <<EOF
PIHOLE_INTERFACE=${IFACE}
IPV4_ADDRESS=${IP_ADDR}
PIHOLE_DNS_1=127.0.0.1#5335
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
BLOCKING_ENABLED=true
DNSMASQ_LISTENING=single
CACHE_SIZE=10000
DNSSEC=false
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
EOF

curl -sSL https://install.pi-hole.net | sudo bash /dev/stdin --unattended
```

Generate `WEBPASSWORD` with double SHA-256: `echo -n 'pass' | sha256sum | awk '{print $1}' | sha256sum | awk '{print $1}'`. Prompt the user for the password or use 1Password per rule `01-security.md`.

Set `DNSSEC=false` because Unbound handles DNSSEC validation.

**Unbound install and config:**

```bash
sudo apt install unbound
```

Write config to `/etc/unbound/unbound.conf.d/pi-hole.conf`:
```
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: yes
    prefer-ip6: no
    harden-glue: yes
    harden-dnssec-stripped: yes
    hide-identity: yes
    hide-version: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    so-rcvbuf: 1m
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10
```

**Post-install fixes (Debian 12+):**
```bash
sudo systemctl disable --now unbound-resolvconf.service
sudo sed -Ei 's/^unbound_conf=/#unbound_conf=/' /etc/resolvconf.conf 2>/dev/null || true
sudo rm -f /etc/unbound/unbound.conf.d/resolvconf_resolvers.conf
sudo systemctl restart unbound
```

**Validate by running `ph-test`.**

### ts-install

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
```

Prompt the user to authenticate — `sudo tailscale up` prints an auth URL. Pause and wait for confirmation.

**Important:** On the Pi-hole host, use `--accept-dns=false` so Tailscale does not overwrite `/etc/resolv.conf`:
```bash
sudo tailscale up --accept-dns=false
```

**Optional exit node** (ask user):
```bash
sudo tailscale up --advertise-exit-node --accept-dns=false
```
Requires IP forwarding (already set in sysctl by `ph-harden` if `net.ipv4.ip_forward = 1`).

**Update ufw for Tailscale:**
```bash
sudo ufw allow in on tailscale0 to any port 53      # DNS via Tailscale only
sudo ufw allow in on tailscale0 to any port 80      # Pi-hole admin via Tailscale only
sudo ufw allow in on tailscale0 to any port 443
```

**Post-install:** Remind user to disable key expiry in the Tailscale admin console for this server.

**Validate by running `ts-test`.**

### ph-setup

Main orchestrator. Single entry point: `ph-setup`.

**Phases:**
1. System update (`apt-get update && apt-get full-upgrade -y`)
2. Hardening (`ph-harden`, then `ph-harden-test`)
3. Pi-hole + Unbound (`ph-install`, then `ph-test`) — prompt for confirmation
4. Tailscale (`ts-install`, then `ts-test`) — prompt for confirmation
5. Final report

Handle partial runs: if user declines Tailscale, still produce a report.

**Final report includes:**
- Server info: hostname, public IP, OS, kernel
- Hardening: pass/fail counts from `ph-harden-test`
- Pi-hole: pass/fail counts from `ph-test` (or "skipped")
- Tailscale: pass/fail counts from `ts-test` (or "skipped")
- Action items for any failures
- SSH connection details (user, port)
- Pi-hole admin URL

---

## Procedure

1. Read the rules in `~/.config/agents/rules/` and skills in `~/.config/agents/skills/`.
2. Read all existing scripts (`ph-test`, `ts-test`, `ph-update`) to learn patterns and conventions.
3. Build `ph-harden` and `ph-harden-test` — server lockdown first since the VPS is exposed.
4. Build `ph-install` — Pi-hole and Unbound, validate with `ph-test`.
5. Build `ts-install` — Tailscale, validate with `ts-test`.
6. Build `ph-setup` — orchestrator that ties all phases together with the final report.

## Reference Documentation

Sources used to derive the setup steps above. Consult if clarification is needed:

- Debian hardening: https://wiki.debian.org/Hardening
- Ubuntu security: https://ubuntu.com/server/docs/explanation/security/security_suggestions/
- Linux server hardening: https://github.com/imthenachoman/How-To-Secure-A-Linux-Server
- Pi-hole install: https://docs.pi-hole.net/main/basic-install/
- Pi-hole post-install: https://docs.pi-hole.net/main/post-install/
- Pi-hole + Unbound: https://docs.pi-hole.net/guides/dns/unbound/
- Tailscale Linux: https://tailscale.com/docs/install/linux
- fail2ban: https://github.com/fail2ban/fail2ban/wiki
- UFW: https://help.ubuntu.com/community/UFW
