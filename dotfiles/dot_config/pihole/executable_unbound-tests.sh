#!/usr/bin/env bash
# ============================================================
#  unbound-tests.sh — Quick diagnostics for Unbound DNS
# ============================================================

set -euo pipefail

DNS_SERVER="${1:-127.0.0.1}"
GOOD_DOMAIN="google.com"
DNSSEC_FAIL_DOMAIN="dnssec-failed.org"
BLOCKED_DOMAIN="doubleclick.net"

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Result tracking ──────────────────────────────────────────
declare -a SUMMARY_RESULTS=()

pass() {
    printf '  %b✔%b  %s\n' "${GREEN}" "${RESET}" "$*"
    SUMMARY_RESULTS+=("${GREEN}✔ PASS${RESET}  $*")
}
fail() {
    printf '  %b✗%b  %s\n' "${RED}" "${RESET}" "$*"
    SUMMARY_RESULTS+=("${RED}✗ FAIL${RESET}  $*")
}
info() { printf '  %b→%b  %s\n' "${CYAN}" "${RESET}" "$*"; }
fix()  { printf '  %b💡 Fix:%b %s\n' "${YELLOW}" "${RESET}" "$*"; }
header() {
    printf '\n%b▶ %s%b\n' "${BOLD}${YELLOW}" "$*" "${RESET}"
}

check_deps() {
    local missing=0
    for cmd in dig unbound-control unbound-checkconf ss; do
        if ! command -v "${cmd}" &>/dev/null; then
            printf '%bMissing dependency: %s%b\n' "${RED}" "${cmd}" "${RESET}"
            case "${cmd}" in
                dig)
                    fix "sudo apt install dnsutils   # Debian/Ubuntu"
                    fix "sudo dnf install bind-utils  # Fedora/RHEL" ;;
                unbound-control|unbound-checkconf)
                    fix "sudo apt install unbound     # Debian/Ubuntu"
                    fix "sudo dnf install unbound     # Fedora/RHEL" ;;
                ss)
                    fix "sudo apt install iproute2    # Debian/Ubuntu"
                    fix "sudo dnf install iproute     # Fedora/RHEL" ;;
            esac
            missing=1
        fi
    done
    [[ "${missing}" -eq 1 ]] && exit 1
}

# ── 1. Config check ──────────────────────────────────────────
test_config() {
    header "Config syntax check"
    if sudo unbound-checkconf 2>&1 | grep -q "no errors"; then
        pass "unbound-checkconf: no errors"
    else
        fail "unbound-checkconf reported issues:"
        sudo unbound-checkconf
        fix "Review the errors above in /etc/unbound/unbound.conf (or included files)"
        fix "Check for typos, duplicate keys, or incorrect indentation"
        fix "Validate with: sudo unbound-checkconf /etc/unbound/unbound.conf"
    fi
}

# ── 2. Service status ────────────────────────────────────────
test_status() {
    header "Service status"
    if sudo unbound-control status 2>&1 | grep -q "is running"; then
        pass "Unbound is running"
    else
        fail "Unbound does not appear to be running"
        fix "sudo systemctl start unbound"
        fix "sudo systemctl enable unbound   # start on boot"
        fix "Check logs: sudo journalctl -u unbound --no-pager -n 20"
    fi
}

# ── 3. Listening on expected port ───────────────────────────
test_listening() {
    header "Network / listening check"
    if sudo ss -tulnp 2>/dev/null | grep -q "unbound\|:53"; then
        pass "Unbound is listening on port 53"
        sudo ss -tulnp | grep "unbound\|:53" | while read -r line; do
            info "${line}"
        done
    else
        fail "Nothing detected on port 53 — Unbound may not be bound correctly"
        fix "Ensure unbound.conf has: interface: 0.0.0.0 (or 127.0.0.1) and port: 53"
        fix "Check if another DNS service is blocking port 53: sudo ss -tulnp | grep :53"
        fix "If systemd-resolved is conflicting: sudo systemctl disable --now systemd-resolved"
        fix "After config changes: sudo systemctl restart unbound"
    fi
}

# ── 4. Basic resolution ──────────────────────────────────────
test_basic_resolution() {
    header "Basic resolution  (${GOOD_DOMAIN} @ ${DNS_SERVER})"
    local result
    result=$(dig @"${DNS_SERVER}" "${GOOD_DOMAIN}" +short 2>/dev/null)
    if [[ -n "${result}" ]]; then
        pass "Resolved ${GOOD_DOMAIN}:"
        printf '%s\n' "${result}" | while read -r ip; do info "${ip}"; done
    else
        fail "Could not resolve ${GOOD_DOMAIN}"
        fix "Verify Unbound is running: sudo unbound-control status"
        fix "Check upstream connectivity: dig @1.1.1.1 ${GOOD_DOMAIN} +short"
        fix "Ensure root hints are present: ls -la /etc/unbound/root.hints"
        fix "Update root hints: wget -O /etc/unbound/root.hints https://www.internic.net/domain/named.root"
        fix "Check for firewall rules blocking outbound DNS (port 53)"
    fi
}

# ── 5. Caching (latency comparison) ─────────────────────────
test_caching() {
    header "Cache speed test  (${GOOD_DOMAIN})"
    local t1 t2
    t1=$(dig @"${DNS_SERVER}" "${GOOD_DOMAIN}" 2>/dev/null | awk '/Query time/ {print $4}')
    t2=$(dig @"${DNS_SERVER}" "${GOOD_DOMAIN}" 2>/dev/null | awk '/Query time/ {print $4}')
    if [[ -z "${t1}" || -z "${t2}" ]]; then
        fail "Could not measure query times (dig may have failed)"
        fix "Verify Unbound is running: sudo unbound-control status"
        return
    fi
    info "First query:  ${t1} ms"
    info "Second query: ${t2} ms"
    if [[ "${t2}" -lt "${t1}" ]]; then
        pass "Cache is working (second query faster)"
    elif [[ "${t2}" -eq 0 ]]; then
        pass "Cache is working (second query: 0 ms)"
    else
        info "Cache result inconclusive (timing may vary on fast networks)"
        fix "Check cache settings in unbound.conf: msg-cache-size, rrset-cache-size"
        fix "Verify cache content: sudo unbound-control dump_cache | head -20"
    fi
}

# ── 6. DNSSEC validation ─────────────────────────────────────
test_dnssec() {
    header "DNSSEC validation"

    # Should SERVFAIL for a deliberately broken domain
    local status
    status=$(dig @"${DNS_SERVER}" "${DNSSEC_FAIL_DOMAIN}" 2>/dev/null | awk '/status:/ {print $6}' | tr -d ',')
    if [[ "${status}" == "SERVFAIL" ]]; then
        pass "DNSSEC working — ${DNSSEC_FAIL_DOMAIN} correctly returned SERVFAIL"
    else
        fail "Expected SERVFAIL for ${DNSSEC_FAIL_DOMAIN}, got: ${status:-no response}"
        fix "Ensure unbound.conf has: module-config: \"validator iterator\""
        fix "Set val-permissive-mode: no  (strict DNSSEC enforcement)"
        fix "Verify trust anchor exists: ls -la /etc/unbound/root.key"
        fix "Regenerate trust anchor: sudo unbound-anchor -a /etc/unbound/root.key"
        fix "After changes: sudo systemctl restart unbound"
    fi

    # Good domain should carry the AD (Authenticated Data) flag
    local ad_flag
    ad_flag=$(dig @"${DNS_SERVER}" "${GOOD_DOMAIN}" +dnssec 2>/dev/null | awk '/flags:/ {print}')
    if printf '%s' "${ad_flag}" | grep -q " ad"; then
        pass "AD flag present on ${GOOD_DOMAIN} — DNSSEC authenticated"
    else
        info "AD flag not set for ${GOOD_DOMAIN} (may be normal depending on trust anchor config)"
    fi
}

# ── 7. Blocklist check ───────────────────────────────────────
test_blocklist() {
    header "Blocklist / RPZ check  (${BLOCKED_DOMAIN})"
    local result rcode
    result=$(dig @"${DNS_SERVER}" "${BLOCKED_DOMAIN}" +short 2>/dev/null)
    rcode=$(dig @"${DNS_SERVER}" "${BLOCKED_DOMAIN}" 2>/dev/null | awk '/status:/ {print $6}' | tr -d ',')
    if [[ "${rcode}" == "NXDOMAIN" || "${result}" == "0.0.0.0" || -z "${result}" ]]; then
        pass "${BLOCKED_DOMAIN} appears to be blocked (${rcode:-no answer})"
    else
        info "${BLOCKED_DOMAIN} resolved to: ${result}"
        info "If you expected this domain to be blocked, check your blocklist config"
        fix "Verify RPZ zone is loaded: sudo unbound-control list_local_zones | grep rpz"
        fix "Check blocklist file path in unbound.conf under rpz: or local-zone:"
        fix "If using Pi-hole for blocking, ensure queries flow through Pi-hole first"
        fix "Reload blocklist: sudo unbound-control reload"
    fi
}

# ── 8. Stats snapshot ────────────────────────────────────────
test_stats() {
    header "Unbound stats snapshot"
    local stats
    stats=$(sudo unbound-control stats_noreset 2>/dev/null)
    if [[ -n "${stats}" ]]; then
        local key val
        for key in total.num.queries total.num.cachehits total.num.cachemiss \
                   total.num.recursivereplies num.query.type.A num.query.type.AAAA; do
            val=$(printf '%s\n' "${stats}" | grep "^${key}=" | cut -d= -f2)
            [[ -n "${val}" ]] && info "${key}: ${val}"
        done
    else
        fail "Could not retrieve stats (is unbound-control configured?)"
        fix "Enable remote control in unbound.conf:"
        fix "  remote-control:"
        fix "    control-enable: yes"
        fix "    control-interface: 127.0.0.1"
        fix "Generate control keys: sudo unbound-control-setup"
        fix "After changes: sudo systemctl restart unbound"
    fi
}

# ── Main ─────────────────────────────────────────────────────
main() {
    printf '\n%b╔══════════════════════════════════════╗%b\n' "${BOLD}" "${RESET}"
    printf '║     Unbound DNS Test Suite           ║\n'
    printf '%b╚══════════════════════════════════════╝%b\n' "${BOLD}" "${RESET}"
    printf '  DNS server under test: %b%s%b\n' "${CYAN}" "${DNS_SERVER}" "${RESET}"
    printf '  Usage: %s [dns-server-ip]\n' "$0"

    check_deps
    test_config
    test_status
    test_listening
    test_basic_resolution
    test_caching
    test_dnssec
    test_blocklist
    test_stats

    print_summary
}

# ── Summary ──────────────────────────────────────────────────
print_summary() {
    local passes=0 failures=0

    printf '\n%b╔══════════════════════════════════════╗%b\n' "${BOLD}" "${RESET}"
    printf '║            Test Summary              ║\n'
    printf '%b╚══════════════════════════════════════╝%b\n' "${BOLD}" "${RESET}"

    local result
    for result in "${SUMMARY_RESULTS[@]}"; do
        printf '  %b\n' "${result}"
        if printf '%s' "${result}" | grep -q "PASS"; then
            ((passes++))
        else
            ((failures++))
        fi
    done

    printf '\n  %bTotal: %s passed, %s failed%b\n' "${BOLD}" "${passes}" "${failures}" "${RESET}"
    if [[ "${failures}" -eq 0 ]]; then
        printf '  %bAll tests passed!%b\n\n' "${GREEN}${BOLD}" "${RESET}"
    else
        printf '  %b%s test(s) need attention.%b\n' "${RED}${BOLD}" "${failures}" "${RESET}"
        printf '\n  %bGeneral troubleshooting steps:%b\n' "${BOLD}${YELLOW}" "${RESET}"
        printf '  %b1.%b Check config:    sudo unbound-checkconf\n' "${YELLOW}" "${RESET}"
        printf '  %b2.%b View logs:       sudo journalctl -u unbound --no-pager -n 30\n' "${YELLOW}" "${RESET}"
        printf '  %b3.%b Restart service: sudo systemctl restart unbound\n' "${YELLOW}" "${RESET}"
        printf '  %b4.%b Run verbosely:   sudo unbound -d -vvv\n' "${YELLOW}" "${RESET}"
        printf '  %b5.%b Re-run tests:    %s %s\n\n' "${YELLOW}" "${RESET}" "$0" "${DNS_SERVER}"
    fi
}

main "$@"
