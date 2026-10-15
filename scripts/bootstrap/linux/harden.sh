#!/usr/bin/env bash
# Harden a fresh Debian/Ubuntu server or VPS before install.sh runs on it:
#   - an admin user with sudo and the SSH keys you logged in with
#   - key-only SSH, root login off, only that user allowed
#   - Tailscale, so SSH can live on the tailnet
#   - ufw: everything inbound closed except the tailnet and the ports you
#     name (optionally only from Cloudflare); public SSH closes once
#     Tailscale is connected
#   - unattended security upgrades
# Run as root on a new machine with only a root login, it needs nothing else
# from this repo:
#   ssh root@HOST 'bash -s -- --user NAME --allow 80 --allow 443' < scripts/bootstrap/linux/harden.sh
# Run from the repo as the admin user (install.sh offers it first, before
# anything is installed, on a server or VPS a basic check finds unhardened),
# it re-runs itself through sudo for that user. Set TS_AUTHKEY to join the
# tailnet unattended; otherwise `tailscale up` prints a login URL and waits
# (skipped without a terminal). Safe to run again. It is never run unasked:
# on a server already in use it would close every port but the tailnet's and
# allow only one SSH user.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: harden.sh --user NAME [options]

  -u, --user NAME      admin user to create or reuse (gets sudo and the SSH keys);
                       under sudo, the user who ran it
  -a, --allow PORT     open PORT[/tcp|/udp] to the internet (repeatable)
      --cloudflare     open --allow ports to Cloudflare's IP ranges only
      --keep-public-ssh  leave SSH open to the internet (rate limited)
  -n, --dry-run        report what would change without changing anything
  -h, --help           show this help

Environment: TS_AUTHKEY joins the tailnet without a login URL.
EOF
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
declare -a ALLOW_PORTS=()
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

# write_file PATH MODE CONTENT [VALIDATOR...]: replaces PATH only when its
# content differs; a validator runs against the new file before it moves in.
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

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -u|--user)
                [[ "$#" -ge 2 ]] || die "$1 needs a value"
                ADMIN_USER="$2"
                shift 2
                continue
                ;;
            -a|--allow)
                [[ "$#" -ge 2 ]] || die "$1 needs a value"
                [[ "$2" =~ ^[0-9]{1,5}(/(tcp|udp))?$ ]] || die "Not a port: $2 (use PORT or PORT/tcp)"
                ALLOW_PORTS+=("$2")
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
            exec sudo bash "${BASH_SOURCE[0]}" --user "${ADMIN_USER}" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
        fi
        log_warn "Not root: the dry run may miss files only root can read"
    fi
    command -v apt-get >/dev/null 2>&1 || die "Needs Debian or Ubuntu (apt-get not found)."
    command -v systemctl >/dev/null 2>&1 || die "Needs systemd (systemctl not found)."
}

home_of() {
    local home=""

    home="$(getent passwd "$1" | cut -d: -f6)"
    [[ -n "${home}" ]] && printf '%s%s\n' "${ROOT_PREFIX}" "${home}"
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

# The admin user gets the keys of whoever logged in: root's, or the cloud
# image's default user when this runs under sudo (AWS root keys only print
# "log in as ubuntu"). Nothing about SSH changes unless the user ends up with
# a key, so this cannot lock you out.
setup_admin_user() {
    local source_user="${SUDO_USER:-root}"
    local source_keys=""
    local user_home=""
    local user_keys=""

    user_home="$(home_of "${ADMIN_USER}" || true)"
    [[ -n "${user_home}" ]] || user_home="${ROOT_PREFIX}/home/${ADMIN_USER}"
    user_keys="${user_home}/.ssh/authorized_keys"
    source_keys="$(home_of "${source_user}" || true)/.ssh/authorized_keys"

    if [[ ! -s "${user_keys}" && ( "${source_user}" == "${ADMIN_USER}" || ! -s "${source_keys}" ) ]]; then
        die "No SSH keys for ${ADMIN_USER} and none to copy from ${source_keys}; add one and run again."
    fi

    if getent passwd "${ADMIN_USER}" >/dev/null; then
        log_info "User ${ADMIN_USER} exists"
    else
        run useradd --create-home --shell /bin/bash "${ADMIN_USER}"
    fi
    run usermod -aG sudo "${ADMIN_USER}"

    # Key-only logins have no password to type, so sudo must not ask for one.
    write_file "${ROOT_PREFIX}/etc/sudoers.d/90-${ADMIN_USER}" 440 \
        "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" visudo -cf

    if [[ -s "${user_keys}" ]]; then
        log_info "${user_keys} already has keys"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "would copy ${source_user}'s SSH keys to ${user_keys}"
    else
        install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${user_home}/.ssh"
        install -m 600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${source_keys}" "${user_keys}"
        log_info "Copied ${source_user}'s SSH keys to ${user_keys}"
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

# sshd keeps the first value it reads for each setting, and Debian and Ubuntu
# read sshd_config.d before the rest, so a 00- file beats cloud-init's
# 50-cloud-init.conf (which turns password logins back on).
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

cloudflare_ranges() {
    curl -fsSL https://www.cloudflare.com/ips-v4
    printf '\n'
    curl -fsSL https://www.cloudflare.com/ips-v6
    printf '\n'
}

# ufw keeps existing connections when it enables, so the session running this
# survives even when public SSH closes.
setup_firewall() {
    local port=""
    local range=""
    local spec=""
    local proto=""
    local -a ranges=()
    local ssh="$1"

    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow in on tailscale0 comment 'tailnet'
    # Lets peers reach this node directly instead of through a relay.
    run ufw allow 41641/udp comment 'tailscale direct'

    if [[ "${CLOUDFLARE}" -eq 1 && "${#ALLOW_PORTS[@]}" -gt 0 ]]; then
        while IFS= read -r range; do
            [[ -n "${range}" ]] && ranges+=("${range}")
        done < <(cloudflare_ranges)
        [[ "${#ranges[@]}" -gt 0 ]] || die "Could not fetch Cloudflare's IP ranges"
    fi

    for spec in ${ALLOW_PORTS[@]+"${ALLOW_PORTS[@]}"}; do
        port="${spec%%/*}"
        proto="tcp"
        [[ "${spec}" == */* ]] && proto="${spec##*/}"
        if [[ "${CLOUDFLARE}" -eq 1 ]]; then
            # Drop an open-to-all rule from an earlier run.
            run ufw --force delete allow "${port}/${proto}" || true
            for range in "${ranges[@]}"; do
                run ufw allow proto "${proto}" from "${range}" to any port "${port}" comment 'cloudflare'
            done
        else
            run ufw allow "${port}/${proto}"
        fi
    done

    if [[ "${ssh}" == public ]]; then
        run ufw limit "${SSH_PORT}/tcp" comment 'public ssh'
    else
        for spec in "${SSH_PORT}/tcp" "${SSH_PORT}" OpenSSH; do
            run ufw --force delete allow "${spec}" || true
            run ufw --force delete limit "${spec}" || true
        done
        log_info "Public SSH closed; SSH only over Tailscale"
    fi

    run ufw --force enable
}

enable_auto_upgrades() {
    write_file "${ROOT_PREFIX}/etc/apt/apt.conf.d/20auto-upgrades" 644 \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
}

main() {
    local ssh_mode="tailnet"
    local ts_name=""

    parse_args "$@"
    preflight
    [[ "${DRY_RUN}" -eq 1 ]] && log_info "Dry run: nothing will change"

    install_packages
    setup_admin_user
    setup_tailscale
    harden_ssh
    SSH_PORT="$(ssh_port)"

    if [[ "${KEEP_PUBLIC_SSH}" -eq 1 ]]; then
        ssh_mode="public"
    elif ! tailscale_connected; then
        ssh_mode="public"
        log_warn "Tailscale is not connected, so public SSH stays open; run this again once it is."
    fi
    setup_firewall "${ssh_mode}"
    enable_auto_upgrades

    if tailscale_connected; then
        ts_name="$(tailscale status --self --peers=false 2>/dev/null | awk 'NR == 1 { print $2 }' || true)"
    fi
    log_info "Done. In a NEW terminal, before closing this one: ssh ${ADMIN_USER}@${ts_name:-<tailscale name>}"
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker publishes ports around ufw; bind them to 127.0.0.1 or the tailnet IP."
    fi
}

main "$@"
