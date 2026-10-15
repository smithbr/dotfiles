#!/usr/bin/env bash
# Check whether a Debian/Ubuntu box is hardened the way harden.sh leaves it,
# changing nothing: key-only SSH with no root login and one allowed user, an
# admin user with sudo and keys, Tailscale connected, ufw denying all inbound
# but the tailnet, unattended upgrades, and what is pending (upgrades, a
# reboot, Docker ports published around ufw). Run it ad hoc on any Linux box;
# it needs nothing else from this repo:
#   ssh HOST 'bash -s' < scripts/bootstrap/linux/harden-test.sh
#   ssh HOST 'sudo bash -s -- --user NAME' < scripts/bootstrap/linux/harden-test.sh
# As root it reads sshd's effective config (sshd -T) and ufw's rules; as a
# user it reads the config files instead and says what it could not see.
# Exits 0 when every check passes and 1 when any fails. install.sh runs it
# with --brief before an install on a server or VPS and offers harden.sh when
# it fails.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: harden-test.sh [options]

  -u, --user NAME   the admin user that should be the one allowed in: under
                    sudo, the user who ran it; otherwise the current user
      --brief       print only the failures, one per line (for scripts)
  -h, --help        show this help

Exit status is 0 when every check passes, 1 when any fails.
EOF
}

# HARDEN_ROOT prefixes every system path so tests can run against a scratch tree.
ROOT_PREFIX="${HARDEN_ROOT:-}"
ADMIN_USER=""
BRIEF=0
PASSES=0
FAILS=0
WARNS=0
SKIPS=0
SSHD_CONFIG=""
SSHD_SOURCE=""
SSH_PORT=22
PUBLIC_SSH=""
TAILSCALE_UP=0

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

section() {
    [[ "${BRIEF}" -eq 1 ]] || printf '\n%s\n' "$1"
}

pass() {
    PASSES=$((PASSES + 1))
    [[ "${BRIEF}" -eq 1 ]] || printf '  ok: %s\n' "$*"
}

fail() {
    FAILS=$((FAILS + 1))
    if [[ "${BRIEF}" -eq 1 ]]; then
        printf '%s\n' "$*"
    else
        printf '  FAIL: %s\n' "$*"
    fi
}

warn() {
    WARNS=$((WARNS + 1))
    [[ "${BRIEF}" -eq 1 ]] || printf '  warn: %s\n' "$*"
}

# Needs root to see; counted so the summary can say to run again with sudo.
skip() {
    SKIPS=$((SKIPS + 1))
    [[ "${BRIEF}" -eq 1 ]] || printf '  skipped: %s\n' "$*"
}

info() {
    [[ "${BRIEF}" -eq 1 ]] || printf '  %s\n' "$*"
}

lower() {
    printf '%s' "$*" | tr '[:upper:]' '[:lower:]'
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -u|--user)
                [[ "$#" -ge 2 ]] || die "$1 needs a value"
                ADMIN_USER="$2"
                shift 2
                ;;
            --brief)
                BRIEF=1
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
    if [[ -z "${ADMIN_USER}" ]]; then
        ADMIN_USER="${SUDO_USER:-$(id -un)}"
    fi
    [[ "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Not a valid user name: ${ADMIN_USER}"
}

home_of() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6
}

# sshd's effective config when sshd -T works (root), else the config files
# the way sshd reads them: Debian and Ubuntu include sshd_config.d/ before
# the rest, and sshd keeps the first value it reads for each setting. Either
# way one "key value" line per setting, keys lowercased.
load_sshd_config() {
    local sshd=""

    sshd="$(command -v sshd 2>/dev/null || true)"
    if [[ -n "${sshd}" ]] && SSHD_CONFIG="$("${sshd}" -T 2>/dev/null)"; then
        SSHD_SOURCE="sshd -T"
        return 0
    fi
    SSHD_CONFIG="$(cat "${ROOT_PREFIX}"/etc/ssh/sshd_config.d/*.conf "${ROOT_PREFIX}/etc/ssh/sshd_config" 2>/dev/null |
        sed 's/#.*//' | awk 'NF { key = tolower($1); $1 = ""; sub(/^[ \t]+/, ""); print key, $0 }' || true)"
    SSHD_SOURCE="the config files"
}

# The first value of a setting, lowercased; empty when unset.
sshd_setting() {
    awk -v key="$1" '$1 == key { $1 = ""; sub(/^ +/, ""); print tolower($0); exit }' <<< "${SSHD_CONFIG}"
}

# Every value of a setting that accumulates (AllowUsers), space separated.
sshd_values() {
    awk -v key="$1" '$1 == key { $1 = ""; sub(/^ +/, ""); printf "%s ", $0 } END { print "" }' <<< "${SSHD_CONFIG}" | sed 's/ *$//'
}

check_ssh() {
    local value allowed

    section "SSH (from ${SSHD_SOURCE})"
    if [[ -z "${SSHD_CONFIG}" ]]; then
        fail "no sshd config found under ${ROOT_PREFIX}/etc/ssh"
        return 0
    fi
    value="$(sshd_setting port)"
    SSH_PORT="${value:-22}"

    value="$(sshd_setting permitrootlogin)"
    if [[ "${value}" == no ]]; then
        pass "root cannot log in over SSH"
    else
        fail "root can log in over SSH (PermitRootLogin ${value:-yes, the default})"
    fi

    value="$(sshd_setting passwordauthentication)"
    if [[ "${value}" == no ]]; then
        pass "password logins are off"
    else
        fail "password logins are allowed (PasswordAuthentication ${value:-yes, the default})"
    fi

    value="$(sshd_setting kbdinteractiveauthentication)"
    [[ -n "${value}" ]] || value="$(sshd_setting challengeresponseauthentication)"
    if [[ "${value}" == no ]]; then
        pass "keyboard-interactive logins are off"
    else
        fail "keyboard-interactive logins are allowed (a PAM password prompt; KbdInteractiveAuthentication ${value:-yes, the default})"
    fi

    value="$(sshd_setting pubkeyauthentication)"
    if [[ "${value:-yes}" == yes ]]; then
        pass "key logins are on"
    else
        fail "key logins are off (PubkeyAuthentication ${value})"
    fi

    allowed="$(sshd_values allowusers)"
    if [[ -z "${allowed}" ]]; then
        warn "any user with a key can log in (no AllowUsers)"
    elif [[ " ${allowed} " == *" ${ADMIN_USER} "* ]]; then
        pass "only ${allowed// /, } may log in"
    else
        fail "AllowUsers (${allowed// /, }) leaves ${ADMIN_USER} out"
    fi

    value="$(sshd_setting maxauthtries)"
    if [[ "${value}" =~ ^[0-9]+$ && "${value}" -le 3 ]]; then
        pass "${value} auth tries per connection"
    else
        warn "${value:-6, the default} auth tries per connection (harden.sh sets 3)"
    fi

    value="$(sshd_setting x11forwarding)"
    if [[ "${value:-no}" == no ]]; then
        pass "X11 forwarding is off"
    else
        warn "X11 forwarding is on"
    fi
}

check_admin_user() {
    local home keys groups

    section "Admin user ${ADMIN_USER}"
    if [[ "${ADMIN_USER}" == root ]]; then
        fail "the admin user is root; run as your admin user or pass --user NAME"
        return 0
    fi
    if ! getent passwd "${ADMIN_USER}" >/dev/null 2>&1; then
        fail "no user ${ADMIN_USER} on this machine"
        return 0
    fi

    groups="$(id -nG "${ADMIN_USER}" 2>/dev/null || true)"
    if [[ " ${groups} " == *" sudo "* || " ${groups} " == *" wheel "* ]]; then
        pass "${ADMIN_USER} can sudo (group)"
    elif [[ -n "$(cat "${ROOT_PREFIX}"/etc/sudoers.d/* 2>/dev/null | grep -E "^${ADMIN_USER}[[:space:]]" || true)" ]]; then
        pass "${ADMIN_USER} can sudo (sudoers.d)"
    elif [[ -d "${ROOT_PREFIX}/etc/sudoers.d" && ! -r "${ROOT_PREFIX}/etc/sudoers.d" ]]; then
        skip "whether ${ADMIN_USER} can sudo needs root to read sudoers.d"
    else
        fail "${ADMIN_USER} cannot sudo"
    fi

    home="$(home_of "${ADMIN_USER}")"
    keys="${ROOT_PREFIX}${home}/.ssh/authorized_keys"
    if [[ -s "${keys}" ]]; then
        pass "${ADMIN_USER} has $(grep -c '^[^#]' "${keys}" 2>/dev/null || printf 0) SSH key(s)"
    elif [[ -d "${ROOT_PREFIX}${home}" && ! -r "${ROOT_PREFIX}${home}" ]]; then
        skip "${ADMIN_USER}'s SSH keys need root to read"
    elif [[ -z "${home}" ]]; then
        fail "${ADMIN_USER} has no home directory"
    else
        fail "${ADMIN_USER} has no SSH keys in ${home}/.ssh/authorized_keys"
    fi
}

check_tailscale() {
    local ip

    section "Tailscale"
    if ! command -v tailscale >/dev/null 2>&1; then
        fail "Tailscale is not installed"
        return 0
    fi
    if ip="$(tailscale ip -4 2>/dev/null | head -n 1)" && [[ -n "${ip}" ]]; then
        TAILSCALE_UP=1
        pass "connected as ${ip}"
    else
        fail "Tailscale is not connected (sudo tailscale up)"
    fi
}

# ufw's live rules when ufw status works (root); else the files that say
# whether it is enabled and what it denies by default, and the rules are
# skipped.
check_firewall() {
    local status="" line rule open="" tailnet=0

    section "Firewall"
    if ! command -v ufw >/dev/null 2>&1 && [[ ! -f "${ROOT_PREFIX}/etc/ufw/ufw.conf" ]]; then
        fail "ufw is not installed"
        return 0
    fi

    if status="$(ufw status verbose 2>/dev/null)" && [[ "${status}" == Status:* ]]; then
        if [[ "${status}" == "Status: active"* ]]; then
            pass "ufw is active"
        else
            fail "ufw is not active (sudo ufw enable)"
            return 0
        fi
        if grep -q '^Default: deny (incoming)' <<< "${status}"; then
            pass "incoming connections are denied by default"
        else
            fail "incoming connections are not denied by default"
        fi
        # One rule per line: "TO  ACTION IN  FROM  # comment", v6 lines doubled.
        while IFS= read -r line; do
            [[ "${line}" == *" IN "* ]] || continue
            [[ "${line}" != *"(v6)"* ]] || continue
            rule="${line%%  *}"
            case "${line}" in
                *"on tailscale0"*)
                    tailnet=1
                    ;;
                "${SSH_PORT}/tcp "*|"${SSH_PORT} "*|"OpenSSH "*)
                    if [[ "${line}" == *" LIMIT IN "* ]]; then
                        PUBLIC_SSH=limited
                    else
                        PUBLIC_SSH=open
                    fi
                    ;;
                "41641/udp "*)
                    ;;
                *" ALLOW IN "*|*" LIMIT IN "*)
                    open="${open} ${rule}"
                    ;;
            esac
        done <<< "${status}"
        if [[ "${tailnet}" -eq 1 ]]; then
            pass "the tailnet (tailscale0) is allowed in"
        else
            fail "the tailnet (tailscale0) is not allowed in"
        fi
        case "${PUBLIC_SSH}" in
            open)
                fail "SSH port ${SSH_PORT} is open to the internet without rate limiting"
                ;;
            limited)
                warn "SSH port ${SSH_PORT} is open to the internet, rate limited (--keep-public-ssh)"
                ;;
            *)
                if [[ "${TAILSCALE_UP}" -eq 1 ]]; then
                    pass "SSH is reachable only over the tailnet"
                else
                    fail "SSH is closed to the internet and Tailscale is not connected: only the console can reach this box"
                fi
                ;;
        esac
        if [[ -n "${open}" ]]; then
            info "open to the internet:${open}"
        else
            info "no other ports are open to the internet"
        fi
        return 0
    fi

    if grep -qx 'ENABLED=yes' "${ROOT_PREFIX}/etc/ufw/ufw.conf" 2>/dev/null; then
        pass "ufw is enabled (/etc/ufw/ufw.conf)"
    else
        fail "ufw is not enabled (sudo ufw enable)"
    fi
    if grep -qx 'DEFAULT_INPUT_POLICY="DROP"' "${ROOT_PREFIX}/etc/default/ufw" 2>/dev/null; then
        pass "incoming connections are denied by default (/etc/default/ufw)"
    else
        fail "incoming connections are not denied by default"
    fi
    skip "the rules (tailnet in, public SSH, open ports) need root: run again with sudo"
}

check_docker() {
    local output line name ports published=""

    command -v docker >/dev/null 2>&1 || return 0
    section "Docker"
    if ! output="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null)"; then
        skip "Docker's published ports need root or the docker group"
        return 0
    fi
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        name="${line%% *}"
        ports="$(grep -oE '(0\.0\.0\.0:|\[::\]:|:::)[0-9]+' <<< "${line}" | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ' || true)"
        [[ -n "${ports}" ]] && published="${published} ${name} (${ports% })"
    done <<< "${output}"
    if [[ -n "${published}" ]]; then
        warn "Docker publishes ports to all interfaces, around ufw:${published}; bind them to 127.0.0.1 or the tailnet IP"
    else
        pass "no container publishes a port to all interfaces"
    fi
}

check_updates() {
    local conf="${ROOT_PREFIX}/etc/apt/apt.conf.d/20auto-upgrades" stamp pending packages

    section "Updates"
    if [[ -x "${ROOT_PREFIX}/usr/bin/unattended-upgrade" ]]; then
        pass "unattended-upgrades is installed"
    else
        fail "unattended-upgrades is not installed"
    fi
    if grep -q 'APT::Periodic::Unattended-Upgrade "1"' "${conf}" 2>/dev/null &&
        grep -q 'APT::Periodic::Update-Package-Lists "1"' "${conf}" 2>/dev/null; then
        pass "unattended upgrades are on"
    else
        fail "unattended upgrades are off (${conf#"${ROOT_PREFIX}"})"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if [[ "$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)" == enabled ]]; then
            pass "the daily upgrade timer is enabled"
        else
            warn "the daily upgrade timer (apt-daily-upgrade.timer) is not enabled"
        fi
    fi

    stamp="${ROOT_PREFIX}/var/lib/apt/periodic/update-success-stamp"
    if [[ -f "${stamp}" ]] && [[ -n "$(find "${stamp}" -mtime +7 2>/dev/null)" ]]; then
        warn "the package lists were last updated over a week ago"
    fi
    if command -v apt-get >/dev/null 2>&1; then
        pending="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)"
        if [[ "${pending:-0}" -gt 0 ]]; then
            warn "${pending} package upgrade(s) pending (sudo apt-get upgrade)"
        else
            pass "no package upgrades pending"
        fi
    fi
    if [[ -f "${ROOT_PREFIX}/var/run/reboot-required" ]]; then
        packages="$(tr '\n' ' ' < "${ROOT_PREFIX}/var/run/reboot-required.pkgs" 2>/dev/null || true)"
        warn "a reboot is required${packages:+ (${packages% })}"
    fi
}

main() {
    parse_args "$@"
    [[ "${OSTYPE}" == linux* || -n "${ROOT_PREFIX}" ]] || die "Linux only"

    if [[ "${BRIEF}" -eq 0 ]]; then
        printf 'Hardening check on %s, admin user %s\n' "$(hostname 2>/dev/null || printf 'this machine')" "${ADMIN_USER}"
    fi
    load_sshd_config
    check_ssh
    check_admin_user
    check_tailscale
    check_firewall
    check_docker
    check_updates

    if [[ "${BRIEF}" -eq 0 ]]; then
        printf '\n%d passed, %d failed, %d warning(s).\n' "${PASSES}" "${FAILS}" "${WARNS}"
        [[ "${SKIPS}" -eq 0 ]] || printf 'Some checks need root: run again with sudo.\n'
        [[ "${FAILS}" -eq 0 ]] || printf 'To harden this box: sudo bash scripts/bootstrap/linux/harden.sh (see its --help).\n'
    fi
    [[ "${FAILS}" -eq 0 ]]
}

main "$@"
