#!/usr/bin/env bash
# Pi-hole v6 with Unbound as its upstream: a recursive, DNSSEC-validating
# resolver on 127.0.0.1#5335, set up as the Pi-hole guide describes and
# ph-test checks (https://docs.pi-hole.net/guides/dns/unbound/).
#
# Unbound comes from apt with the guide's pi-hole.conf (plus hide-identity
# and hide-version, which ph-test wants); Debian's unbound-resolvconf hook,
# which would point the box itself at Unbound, is disabled, and the kernel
# receive buffer so-rcvbuf asks for is raised. Pi-hole comes from its
# official installer, unattended: the installer only skips its dialogs when
# /etc/pihole/pihole.toml exists, so a minimal one is written first
# (upstreams from PIHOLE_UPSTREAMS, default Unbound; DNSSEC off in Pi-hole,
# since Unbound validates). An installed Pi-hole is left to `pihole -up`,
# but its upstreams and DNSSEC setting are brought in line through
# pihole-FTL --config. No web password is set; that is a next step.
#
# Needs root, like the installer; re-runs itself through sudo. Safe to run
# again: each part is skipped, or rewritten, only when it differs. PIHOLE_ROOT
# prefixes every system path so tests can run against a scratch tree, with
# the commands mocked on PATH and no root.

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

PIHOLE_UPSTREAMS="${PIHOLE_UPSTREAMS:-127.0.0.1#5335}"
ROOT_PREFIX="${PIHOLE_ROOT:-}"
PIHOLE_TOML="${ROOT_PREFIX}/etc/pihole/pihole.toml"
UNBOUND_CONF="${ROOT_PREFIX}/etc/unbound/unbound.conf.d/pi-hole.conf"
RESOLVCONF_CONF="${ROOT_PREFIX}/etc/resolvconf.conf"
RESOLVCONF_HOOK="${ROOT_PREFIX}/etc/unbound/unbound.conf.d/resolvconf_resolvers.conf"
SYSCTL_CONF="${ROOT_PREFIX}/etc/sysctl.d/99-unbound.conf"
RMEM_MAX=1048576

if ! command -v apt-get >/dev/null 2>&1; then
    log_warn "apt-get not found; skipping Pi-hole install"
    exit 0
fi

if [[ "${EUID}" -ne 0 && -z "${ROOT_PREFIX}" ]]; then
    exec sudo env PIHOLE_UPSTREAMS="${PIHOLE_UPSTREAMS}" bash "${BASH_SOURCE[0]}" "$@"
fi
export DEBIAN_FRONTEND=noninteractive

unbound_installed() {
    [[ -x "${ROOT_PREFIX}/usr/sbin/unbound" ]]
}

pihole_installed() {
    [[ -x "${ROOT_PREFIX}/usr/bin/pihole-FTL" && -x "${ROOT_PREFIX}/usr/local/bin/pihole" ]]
}

# The guide's pi-hole.conf: loopback only, on 5335, validating, with the
# private ranges kept out of answers.
unbound_conf() {
    cat <<'EOF'
# Unbound as Pi-hole's upstream, from the dotfiles pihole role; rerunning
# the role rewrites this file. https://docs.pi-hole.net/guides/dns/unbound/
server:
    verbosity: 0

    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: yes
    prefer-ip6: no

    # Trust glue only within the server's authority; a trust-anchored zone
    # without DNSSEC data is bogus.
    harden-glue: yes
    harden-dnssec-stripped: yes
    hide-identity: yes
    hide-version: yes

    # Capitalisation randomisation is known to trip DNSSEC at times.
    use-caps-for-id: no

    # Keep UDP answers below the fragmentation threshold (DNS Flag Day 2020).
    edns-buffer-size: 1232

    prefetch: yes
    num-threads: 1

    # Needs net.core.rmem_max raised (sysctl.d/99-unbound.conf).
    so-rcvbuf: 1m

    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10
    private-address: 192.0.2.0/24
    private-address: 198.51.100.0/24
    private-address: 203.0.113.0/24
    private-address: 255.255.255.255/32
    private-address: 2001:db8::/32
EOF
}

# Write FILE from stdin when it is missing or differs; true when it changed.
write_if_changed() {
    local file="$1" content
    content="$(cat)"
    if [[ -f "${file}" && "$(cat "${file}")" == "${content}" ]]; then
        return 1
    fi
    mkdir -p "$(dirname "${file}")"
    printf '%s\n' "${content}" > "${file}"
    chmod 644 "${file}"
}

ensure_unbound() {
    local changed=0

    if unbound_installed; then
        log_info "Unbound already installed"
    else
        log_info "Installing Unbound"
        apt-get install -y -qq unbound
        changed=1
    fi

    if unbound_conf | write_if_changed "${UNBOUND_CONF}"; then
        log_info "Wrote ${UNBOUND_CONF} (Unbound on 127.0.0.1#5335, validating)"
        changed=1
    else
        log_info "${UNBOUND_CONF} already in place"
    fi

    # Debian's resolvconf hook would make Unbound this box's own resolver and
    # feed it the DHCP resolvers as forwarders; Pi-hole is the only client.
    if command -v systemctl >/dev/null 2>&1 &&
        { systemctl is-enabled unbound-resolvconf.service >/dev/null 2>&1 ||
          systemctl is-active unbound-resolvconf.service >/dev/null 2>&1; }; then
        log_info "Disabling unbound-resolvconf (it would point this box at Unbound)"
        systemctl disable --now unbound-resolvconf.service
        changed=1
    fi
    if [[ -f "${RESOLVCONF_CONF}" ]] && grep -q '^unbound_conf=' "${RESOLVCONF_CONF}"; then
        log_info "Commenting out unbound_conf in ${RESOLVCONF_CONF}"
        sed -Ei 's/^unbound_conf=/#unbound_conf=/' "${RESOLVCONF_CONF}"
        changed=1
    fi
    if [[ -f "${RESOLVCONF_HOOK}" ]]; then
        log_info "Removing ${RESOLVCONF_HOOK}"
        rm -f "${RESOLVCONF_HOOK}"
        changed=1
    fi

    # so-rcvbuf: 1m is refused, with a warning at every start, until the
    # kernel allows a buffer that large.
    if printf 'net.core.rmem_max=%s\n' "${RMEM_MAX}" | write_if_changed "${SYSCTL_CONF}"; then
        log_info "Wrote ${SYSCTL_CONF} (net.core.rmem_max=${RMEM_MAX} for so-rcvbuf)"
        if command -v sysctl >/dev/null 2>&1; then
            sysctl -q -w "net.core.rmem_max=${RMEM_MAX}" || log_warn "Could not raise net.core.rmem_max now; it applies at the next boot"
        fi
    fi

    if ! unbound-checkconf >/dev/null; then
        log_error "unbound-checkconf rejects the configuration; fix it before Pi-hole uses it"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now unbound >/dev/null
        if [[ "${changed}" -eq 1 ]]; then
            log_info "Restarting Unbound"
            systemctl restart unbound
        fi
    fi
    if command -v dig >/dev/null 2>&1; then
        if [[ -n "$(dig @127.0.0.1 -p 5335 pi-hole.net +short +time=5 +tries=1 2>/dev/null)" ]]; then
            log_info "Unbound resolves pi-hole.net on 127.0.0.1#5335"
        else
            log_warn "Unbound answered nothing for pi-hole.net on 127.0.0.1#5335; check: sudo unbound-control status; ph-test"
        fi
    fi
}

# Quoted TOML strings for the upstreams, as pihole-FTL --config takes them too.
upstreams_toml() {
    local server list=""
    for server in ${PIHOLE_UPSTREAMS}; do
        list="${list:+${list}, }\"${server}\""
    done
    printf '[%s]' "${list}"
}

ensure_pihole() {
    if pihole_installed; then
        log_info "Pi-hole already installed, skipping (pihole -up updates it)"
        return 0
    fi

    if [[ ! -f "${PIHOLE_TOML}" ]]; then
        log_info "Seeding ${PIHOLE_TOML} with upstreams ${PIHOLE_UPSTREAMS}"
        mkdir -p "$(dirname "${PIHOLE_TOML}")"
        printf '[dns]\n  upstreams = %s\n  dnssec = false\n' "$(upstreams_toml)" > "${PIHOLE_TOML}"
    fi

    log_info "Installing Pi-hole"
    curl -fsSL https://install.pi-hole.net | bash /dev/stdin --unattended
    pihole_installed || { log_error "The Pi-hole installer finished but pihole-FTL is missing"; return 1; }
    log_info "Pi-hole installed. Set the web password: sudo pihole setpassword"
}

# Pi-hole's live settings, as the installer or the web UI may have left
# them: upstreams are Unbound (or PIHOLE_UPSTREAMS) and DNSSEC stays off in
# Pi-hole, since Unbound validates and FTL would only double the work.
configure_pihole() {
    local wanted current
    pihole_installed || return 0

    wanted="$(upstreams_toml)"
    current="$(pihole-FTL --config dns.upstreams 2>/dev/null || true)"
    if [[ "$(tr -d '[]" ' <<< "${current}")" != "$(tr -d '[]" ' <<< "${wanted}")" ]]; then
        log_info "Pointing Pi-hole at ${PIHOLE_UPSTREAMS} (was ${current:-unset})"
        pihole-FTL --config dns.upstreams "${wanted}" >/dev/null
    fi
    current="$(pihole-FTL --config dns.dnssec 2>/dev/null || true)"
    if [[ "${current}" != false ]]; then
        log_info "Turning Pi-hole's own DNSSEC off (Unbound validates)"
        pihole-FTL --config dns.dnssec false >/dev/null
    fi
}

ensure_unbound
ensure_pihole
configure_pihole
