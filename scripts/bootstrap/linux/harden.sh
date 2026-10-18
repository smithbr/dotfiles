#!/usr/bin/env bash
# Harden a Debian server or VPS before install.sh runs on it: an admin user
# with sudo and the SSH keys you logged in with, key-only SSH for that user
# alone, Tailscale, ufw closed to all but the tailnet and the ports you name,
# unattended upgrades. Piped over ssh as root it needs nothing else from the
# repo:
#   ssh root@HOST 'bash -s -- --user NAME --allow 80 --allow 443' < scripts/bootstrap/linux/harden.sh
#
# Options: --help. When public SSH closes, what is checked before the first
# change, and rerunning: scripts/bootstrap/README.md.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: harden.sh --user NAME [options]

  -u, --user NAME      admin user to create or reuse (gets sudo and the SSH keys);
                       under sudo, the user who ran it
  -a, --allow PORT     open PORT[/tcp|/udp] to the internet (repeatable)
  -l, --lan PORT       open PORT[/tcp|/udp] to this box's own network only
                       (repeatable; a Pi-hole gets 53, 80, 443, and its DHCP
                       and NTP ports when they are on, without asking)
      --cloudflare     open --allow ports to Cloudflare's IP ranges only
      --keep-public-ssh  leave SSH open to the internet (rate limited)
  -n, --dry-run        report what would change without changing anything
  -h, --help           show this help

Public SSH closes only when this session came in over Tailscale or from the
console; from anywhere else it stays open, rate limited, until you run this
again over Tailscale.
Environment: TS_AUTHKEY joins the tailnet without a login URL.
USAGE
}

# Piped over ssh there is no script file and no repo beside it, so fall back
# to plain loggers when common.sh is not there.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi
if [[ -n "${BASEDIR:-}" && -f "${BASEDIR}/scripts/common.sh" ]]; then
    source "${BASEDIR}/scripts/common.sh"
else
    log_info() { printf 'info: %s\n' "$*"; }
    log_warn() { printf 'warning: %s\n' "$*" >&2; }
    log_error() { printf 'error: %s\n' "$*" >&2; }
fi

# HARDEN_ROOT prefixes every system path so tests can run against a scratch tree.
ROOT_PREFIX="${HARDEN_ROOT:-}"
DRY_RUN=0
ADMIN_USER=""
CLOUDFLARE=0
KEEP_PUBLIC_SSH=0
SSH_PORT=22
SSH_MODE=tailnet
SOURCE_USER=""
SOURCE_KEYS=""
USER_HOME=""
USER_KEYS=""
declare -a ALLOW_PORTS=()
declare -a LAN_PORTS=()
declare -a LAN_IFACES=()
# "iface<TAB>cidr" pairs the LAN rules are made from.
declare -a LAN_SUBNETS=()
declare -a CLOUDFLARE_RANGES=()
declare -a EXTRA_ARGS=()

die() {
    log_error "$*"
    exit 1
}

run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "would run: $*"
        return 0
    fi
    "$@"
}

# write_file PATH MODE CONTENT [VALIDATOR...]: replace PATH when CONTENT differs,
# once VALIDATOR accepts the new file. Its temp name holds a dot, which
# sudoers.d ignores and *.conf misses.
write_file() {
    local path="$1"
    local mode="$2"
    local content="$3"
    local tmp=""
    shift 3

    if [[ -f "${path}" && "$(cat "${path}")" == "${content}" ]]; then
        log_info "${path} already up to date"
        return 0
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "would write ${path}:"
        printf '%s\n' "${content}" | sed 's/^/    /'
        return 0
    fi

    mkdir -p "$(dirname "${path}")"
    tmp="$(mktemp "${path}.XXXXXX")"
    printf '%s\n' "${content}" > "${tmp}"
    chmod "${mode}" "${tmp}"
    if [[ "$#" -gt 0 ]] && ! "$@" "${tmp}" >/dev/null; then
        rm -f "${tmp}"
        die "${path} failed validation; left unchanged"
    fi
    mv "${tmp}" "${path}"
    log_info "Wrote ${path}"
}

# PORT or PORT/tcp or PORT/udp, 1 to 65535.
valid_port_spec() {
    [[ "$1" =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]] &&
        (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= 65535 ))
}

# A port spec as PORT/PROTO, tcp when the spec names none.
port_proto() {
    if [[ "$1" == */* ]]; then
        printf '%s\n' "$1"
    else
        printf '%s/tcp\n' "$1"
    fi
}

add_lan_port() {
    local spec
    for spec in ${LAN_PORTS[@]+"${LAN_PORTS[@]}"}; do
        [[ "${spec}" != "$1" ]] || return 0
    done
    LAN_PORTS+=("$1")
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -u|--user)
                [[ "$#" -ge 2 ]] || die "$1 needs a value"
                ADMIN_USER="$2"
                shift 2
                continue
                ;;
            -a|--allow|-l|--lan)
                [[ "$#" -ge 2 ]] || die "$1 needs a value"
                valid_port_spec "$2" || die "Not a port: $2 (use PORT or PORT/tcp, 1 to 65535)"
                if [[ "$1" == -a || "$1" == --allow ]]; then
                    ALLOW_PORTS+=("$2")
                else
                    add_lan_port "$(port_proto "$2")"
                fi
                EXTRA_ARGS+=("$1" "$2")
                shift 2
                ;;
            --cloudflare)
                CLOUDFLARE=1
                EXTRA_ARGS+=("$1")
                shift
                ;;
            --keep-public-ssh)
                KEEP_PUBLIC_SSH=1
                EXTRA_ARGS+=("$1")
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "Unknown argument: $1"
                ;;
        esac
    done

    # From the repo as the admin user, or under sudo, that user is the one.
    if [[ -z "${ADMIN_USER}" ]]; then
        if [[ "${EUID}" -ne 0 ]]; then
            ADMIN_USER="$(id -un)"
        else
            ADMIN_USER="${SUDO_USER:-}"
        fi
    fi
    [[ -n "${ADMIN_USER}" ]] || { usage >&2; die "--user is required"; }
    [[ "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Not a valid user name: ${ADMIN_USER}"
    [[ "${ADMIN_USER}" != root ]] || die "--user must not be root"
}

preflight() {
    if [[ "${EUID}" -ne 0 ]]; then
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            if [[ ! -f "${BASH_SOURCE[0]}" ]] || ! command -v sudo >/dev/null 2>&1; then
                die "Run as root (or with sudo bash)."
            fi
            # sudo resets the environment; the auth key and where this
            # session came from must survive the re-exec.
            exec sudo --preserve-env=SSH_CONNECTION,SSH_CLIENT,TS_AUTHKEY \
                bash "${BASH_SOURCE[0]}" --user "${ADMIN_USER}" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
        fi
        log_warn "Not root: the dry run may miss files only root can read"
    fi
    command -v apt-get >/dev/null 2>&1 || die "Needs Debian (apt-get not found)."
    command -v systemctl >/dev/null 2>&1 || die "Needs systemd (systemctl not found)."
}

home_of() {
    local home=""

    home="$(getent passwd "$1" | cut -d: -f6)"
    [[ -n "${home}" ]] && printf '%s%s\n' "${ROOT_PREFIX}" "${home}"
}

# The key lines of FILE that log a user in: not comments, and not keys tied
# to a command (a cloud image's root key only prints "log in as admin").
usable_keys() {
    grep -Ev '^[[:space:]]*(#|$)' "$1" 2>/dev/null | grep -v 'command=' || true
}

# The admin user gets the keys of whoever logged in. With none to give, key-only
# SSH would lock you out, so this runs before anything changes.
plan_admin_user() {
    SOURCE_USER="${SUDO_USER:-root}"
    USER_HOME="$(home_of "${ADMIN_USER}" || true)"
    [[ -n "${USER_HOME}" ]] || USER_HOME="${ROOT_PREFIX}/home/${ADMIN_USER}"
    USER_KEYS="${USER_HOME}/.ssh/authorized_keys"
    SOURCE_KEYS="$(home_of "${SOURCE_USER}" || true)/.ssh/authorized_keys"

    [[ -z "$(usable_keys "${USER_KEYS}")" ]] || return 0
    if [[ "${SOURCE_USER}" == "${ADMIN_USER}" || -z "$(usable_keys "${SOURCE_KEYS}")" ]]; then
        die "No SSH keys for ${ADMIN_USER} and none to copy from ${SOURCE_KEYS} (keys tied to a command= do not count); add one and run again."
    fi
}

pihole_here() {
    [[ -x "${ROOT_PREFIX}/usr/bin/pihole-FTL" ]]
}

# An FTL setting as pihole-FTL --config prints it; empty when it cannot say.
ftl_config() {
    pihole-FTL --config "$1" 2>/dev/null || true
}

# The interfaces that carry a default route, apart from the tailnet's.
lan_ifaces() {
    { ip -o -4 route show default 2>/dev/null; ip -o -6 route show default 2>/dev/null; } |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) !~ /^tailscale/) print $(i + 1) }' |
        sort -u
}

# The networks on IFACE: the IPv4 subnets routed on the link and every IPv6
# prefix routed there (link-local included), one per line.
lan_subnets_on() {
    ip -o -4 route show dev "$1" scope link 2>/dev/null | awk '$1 ~ /\// { print $1 }'
    ip -o -6 route show dev "$1" 2>/dev/null | awk '$1 ~ /\// { print $1 }'
}

# The LAN ports and the LAN itself, found before anything changes. A Pi-hole's
# DNS, admin page, and DHCP and NTP when FTL serves them stay open to the LAN.
plan_lan() {
    local iface subnet found where=""

    if pihole_here; then
        add_lan_port 53/tcp
        add_lan_port 53/udp
        add_lan_port 80/tcp
        add_lan_port 443/tcp
        [[ "$(ftl_config dhcp.active)" != true ]] || add_lan_port 67/udp
        [[ "$(ftl_config ntp.ipv4.active)" != true ]] || add_lan_port 123/udp
        log_info "Pi-hole found: ${LAN_PORTS[*]} stay open to the LAN"
    fi
    [[ "${#LAN_PORTS[@]}" -gt 0 ]] || return 0

    while IFS= read -r iface; do
        [[ -n "${iface}" ]] && LAN_IFACES+=("${iface}")
    done < <(lan_ifaces)
    [[ "${#LAN_IFACES[@]}" -gt 0 ]] || die "No default route, so there is no LAN to open ${LAN_PORTS[*]} to; nothing changed."

    for iface in "${LAN_IFACES[@]}"; do
        found=0
        while IFS= read -r subnet; do
            [[ -n "${subnet}" ]] || continue
            LAN_SUBNETS+=("${iface}"$'\t'"${subnet}")
            where="${where} ${subnet} on ${iface},"
            found=1
        done < <(lan_subnets_on "${iface}")
        if [[ "${found}" -eq 0 ]]; then
            log_warn "No subnet routed on ${iface}; opening ${LAN_PORTS[*]} on it to the private ranges instead"
            for subnet in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7 fe80::/10; do
                LAN_SUBNETS+=("${iface}"$'\t'"${subnet}")
                where="${where} ${subnet} on ${iface},"
            done
        fi
    done
    log_info "LAN:${where%,}"
}

# Cloudflare's published ranges, fetched before anything changes and checked
# to look like CIDRs, so a bad body never reaches ufw halfway through.
plan_cloudflare() {
    local v4 v6 range

    [[ "${CLOUDFLARE}" -eq 1 && "${#ALLOW_PORTS[@]}" -gt 0 ]] || return 0
    v4="$(curl -fsSL https://www.cloudflare.com/ips-v4)" || die "Could not fetch Cloudflare's IPv4 ranges"
    v6="$(curl -fsSL https://www.cloudflare.com/ips-v6)" || die "Could not fetch Cloudflare's IPv6 ranges"
    while IFS= read -r range; do
        [[ -n "${range}" ]] || continue
        [[ "${range}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ || "${range}" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] ||
            die "Cloudflare's range list holds something that is not a CIDR: ${range}"
        CLOUDFLARE_RANGES+=("${range}")
    done <<< "${v4}"$'\n'"${v6}"
    [[ -n "${v4//[[:space:]]/}" && -n "${v6//[[:space:]]/}" ]] || die "Cloudflare's range lists came back empty"
}

install_packages() {
    log_info "Updating packages"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q
    run env DEBIAN_FRONTEND=noninteractive apt-get -q -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        full-upgrade
    run env DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
        ca-certificates curl sudo ufw unattended-upgrades
}

setup_admin_user() {
    local tmp=""

    if getent passwd "${ADMIN_USER}" >/dev/null; then
        log_info "User ${ADMIN_USER} exists"
    else
        run useradd --create-home --shell /bin/bash "${ADMIN_USER}"
    fi
    run usermod -aG sudo "${ADMIN_USER}"

    # Key-only logins have no password to type, so sudo must not ask for one.
    write_file "${ROOT_PREFIX}/etc/sudoers.d/90-${ADMIN_USER}" 440 \
        "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" visudo -cf

    if [[ -n "$(usable_keys "${USER_KEYS}")" ]]; then
        log_info "${USER_KEYS} already has keys"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "would copy ${SOURCE_USER}'s SSH keys to ${USER_KEYS}"
    else
        tmp="$(mktemp)"
        usable_keys "${SOURCE_KEYS}" > "${tmp}"
        install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${USER_HOME}/.ssh"
        install -m 600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${tmp}" "${USER_KEYS}"
        rm -f "${tmp}"
        log_info "Copied ${SOURCE_USER}'s SSH keys to ${USER_KEYS}"
    fi
}

tailscale_connected() {
    command -v tailscale >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1
}

setup_tailscale() {
    local key_file=""

    if command -v tailscale >/dev/null 2>&1; then
        log_info "Tailscale already installed"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "would install Tailscale from https://tailscale.com/install.sh"
    else
        log_info "Installing Tailscale"
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    if tailscale_connected; then
        log_info "Tailscale connected as $(tailscale ip -4 | head -n 1)"
        return 0
    fi

    if [[ -n "${TS_AUTHKEY:-}" ]]; then
        # Passed by file so the key never shows up in the process list.
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log_info "would run: tailscale up --auth-key=file:<TS_AUTHKEY>"
            return 0
        fi
        key_file="$(mktemp)"
        chmod 600 "${key_file}"
        printf '%s' "${TS_AUTHKEY}" > "${key_file}"
        tailscale up --auth-key="file:${key_file}" || log_warn "tailscale up failed"
        rm -f "${key_file}"
    elif [[ ! -t 0 ]]; then
        log_warn "No terminal to log Tailscale in from; run: sudo tailscale up"
    else
        log_info "Open the login URL below to add this machine to your tailnet"
        run tailscale up || log_warn "tailscale up failed"
    fi
}

sshd_bin() {
    command -v sshd 2>/dev/null || printf '/usr/sbin/sshd\n'
}

ssh_port() {
    local port=""

    port="$("$(sshd_bin)" -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
    printf '%s\n' "${port:-22}"
}

# A 00- drop-in wins: sshd keeps the first value it reads, and Debian reads
# sshd_config.d before the rest, so it beats cloud-init's 50-cloud-init.conf.
harden_ssh() {
    local config_dir="${ROOT_PREFIX}/etc/ssh/sshd_config.d"
    local dropin="${config_dir}/00-harden.conf"
    local previous=""
    local content=""

    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "${ROOT_PREFIX}/etc/ssh/sshd_config" 2>/dev/null; then
        die "/etc/ssh/sshd_config does not include sshd_config.d/; harden SSH by hand."
    fi

    content="# Managed by dotfiles harden.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers ${ADMIN_USER}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no"

    [[ -f "${dropin}" ]] && previous="$(cat "${dropin}")"
    write_file "${dropin}" 644 "${content}"
    [[ "${DRY_RUN}" -eq 1 || "${previous}" == "${content}" ]] && return 0

    # sshd -t checks the whole config, so test it in place and put the old
    # file back if it fails rather than reloading into a broken sshd.
    if ! "$(sshd_bin)" -t; then
        if [[ -n "${previous}" ]]; then
            printf '%s\n' "${previous}" > "${dropin}"
        else
            rm -f "${dropin}"
        fi
        die "sshd rejected the new config; restored the previous one"
    fi
    # Existing sessions survive a reload.
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    log_info "SSH reloaded: keys only, no root, only ${ADMIN_USER}"
}

# Where this session came from: SSH_CONNECTION (kept through the sudo
# re-exec), else what who knows about this terminal; empty at the console.
session_client() {
    local client="${SSH_CONNECTION:-}"

    [[ -n "${client}" ]] || client="${SSH_CLIENT:-}"
    client="${client%% *}"
    [[ -n "${client}" ]] || client="$(who -m 2>/dev/null | sed -nE 's/.*\((.*)\)[[:space:]]*$/\1/p' | head -n 1 || true)"
    printf '%s\n' "${client}"
}

# Tailscale addresses: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
tailnet_address() {
    local address=""

    # No ${1,,}: the tests run this under macOS's bash 3.2.
    address="$(tr '[:upper:]' '[:lower:]' <<< "$1")"

    if [[ "${address}" =~ ^100\.([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
        (( BASH_REMATCH[1] >= 64 && BASH_REMATCH[1] <= 127 ))
        return
    fi
    [[ "${address}" == fd7a:115c:a1e0:* ]]
}

# Whether this process sits on a pseudo-terminal (an SSH session or a
# terminal window) rather than a console or no terminal at all.
on_pseudo_terminal() {
    local tty=""

    tty="$(ps -o tty= -p "$$" 2>/dev/null | tr -d ' ' || true)"
    [[ "${tty}" == pts* || "${tty}" == ttys* ]]
}

# Public SSH may close only when this session came in over Tailscale, which
# proves that door works, or when no SSH session is at stake. Sets SSH_MODE.
decide_ssh_mode() {
    local client=""

    SSH_MODE=tailnet

    if [[ "${KEEP_PUBLIC_SSH}" -eq 1 ]]; then
        SSH_MODE=public
        return 0
    fi
    if ! tailscale_connected; then
        log_warn "Tailscale is not connected, so public SSH stays open; run this again over Tailscale once it is."
        SSH_MODE=public
        return 0
    fi
    client="$(session_client)"
    if [[ -n "${client}" ]]; then
        if tailnet_address "${client}"; then
            log_info "This session came in from ${client} over Tailscale, so public SSH can close"
        else
            log_warn "This session came in from ${client}, not over Tailscale, so public SSH stays open; log in as ${ADMIN_USER} over Tailscale and run this again to close it."
            SSH_MODE=public
            return 0
        fi
    elif on_pseudo_terminal; then
        log_warn "Cannot tell where this session came in from (no SSH_CONNECTION, and who knows nothing of this terminal), so public SSH stays open; run this again as: sudo --preserve-env=SSH_CONNECTION bash ${BASH_SOURCE[0]}"
        SSH_MODE=public
        return 0
    else
        log_info "No SSH session is at stake here, so public SSH can close"
    fi
}

# Services listening on every address that only the tailnet and the LAN
# rules will reach once ufw is on, so nothing goes dark unnoticed.
report_other_listeners() {
    local covered=" ${SSH_PORT}/tcp 41641/udp " spec proto address host port hidden=""

    for spec in ${ALLOW_PORTS[@]+"${ALLOW_PORTS[@]}"} ${LAN_PORTS[@]+"${LAN_PORTS[@]}"}; do
        covered="${covered}$(port_proto "${spec}") "
    done
    while read -r proto address; do
        [[ -n "${address}" ]] || continue
        port="${address##*:}"
        host="${address%:*}"
        host="${host#[}"
        host="${host%]}"
        case "${host}" in
            127.*|::1|::ffff:127.*) continue ;;
        esac
        ! tailnet_address "${host}" || continue
        spec="${port}/${proto}"
        [[ "${covered}" == *" ${spec} "* || "${hidden}" == *" ${spec}"* ]] || hidden="${hidden} ${spec}"
    done < <(ss -tulnH 2>/dev/null | awk '$1 == "tcp" || $1 == "udp" { print $1, $5 }' || true)
    [[ -z "${hidden}" ]] || log_warn "Listening, and reachable only over the tailnet once ufw is on:${hidden}"
}

# ufw keeps existing connections when it enables, so the session running this
# survives even when public SSH closes.
setup_firewall() {
    local ssh_mode="$1"
    local port=""
    local proto=""
    local range=""
    local spec=""
    local pair=""

    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow in on tailscale0 comment 'tailnet'
    # Lets peers reach this node directly instead of through a relay.
    run ufw allow 41641/udp comment 'tailscale direct'

    for spec in ${ALLOW_PORTS[@]+"${ALLOW_PORTS[@]}"}; do
        spec="$(port_proto "${spec}")"
        port="${spec%%/*}"
        proto="${spec##*/}"
        if [[ "${CLOUDFLARE}" -eq 1 ]]; then
            # Drop an open-to-all rule from an earlier run.
            run ufw --force delete allow "${port}/${proto}" || true
            for range in "${CLOUDFLARE_RANGES[@]}"; do
                run ufw allow proto "${proto}" from "${range}" to any port "${port}" comment 'cloudflare'
            done
        else
            run ufw allow "${port}/${proto}"
        fi
    done

    for spec in ${LAN_PORTS[@]+"${LAN_PORTS[@]}"}; do
        port="${spec%%/*}"
        proto="${spec##*/}"
        for pair in "${LAN_SUBNETS[@]}"; do
            run ufw allow in on "${pair%%$'\t'*}" from "${pair#*$'\t'}" to any port "${port}" proto "${proto}" comment 'lan'
        done
    done

    if [[ "${ssh_mode}" == public ]]; then
        run ufw limit "${SSH_PORT}/tcp" comment 'public ssh'
    else
        for spec in "${SSH_PORT}/tcp" "${SSH_PORT}" OpenSSH; do
            run ufw --force delete allow "${spec}" || true
            run ufw --force delete limit "${spec}" || true
        done
        log_info "Public SSH closed; SSH only over Tailscale"
    fi

    report_other_listeners
    run ufw --force enable
}

enable_auto_upgrades() {
    write_file "${ROOT_PREFIX}/etc/apt/apt.conf.d/20auto-upgrades" 644 \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
}

main() {
    local ts_name=""

    parse_args "$@"
    preflight
    [[ "${DRY_RUN}" -eq 1 ]] && log_info "Dry run: nothing will change"

    # Everything that can stop the run, before the first change.
    plan_admin_user
    plan_lan
    plan_cloudflare

    install_packages
    setup_admin_user
    setup_tailscale
    harden_ssh
    SSH_PORT="$(ssh_port)"
    decide_ssh_mode
    setup_firewall "${SSH_MODE}"
    enable_auto_upgrades

    if tailscale_connected; then
        ts_name="$(tailscale status --self --peers=false 2>/dev/null | awk 'NR == 1 { print $2 }' || true)"
    fi
    log_info "Done. In a NEW terminal, before closing this one: ssh ${ADMIN_USER}@${ts_name:-<tailscale name>}"
    [[ "${#LAN_PORTS[@]}" -eq 0 ]] || log_info "Open to the LAN: ${LAN_PORTS[*]}"
    if [[ -f "${ROOT_PREFIX}/var/run/reboot-required" ]]; then
        log_warn "A reboot is required to finish the package upgrade."
    fi
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker publishes ports around ufw; bind them to 127.0.0.1 or the tailnet IP."
    fi
}

main "$@"
