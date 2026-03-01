#!/usr/bin/env bash
# ============================================================
#  unbound-tests.sh — Quick diagnostics for Unbound DNS
# ============================================================

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
    echo -e "  ${GREEN}✔${RESET}  $*"
    SUMMARY_RESULTS+=("${GREEN}✔ PASS${RESET}  $*")
}
fail() {
    echo -e "  ${RED}✗${RESET}  $*"
    SUMMARY_RESULTS+=("${RED}✗ FAIL${RESET}  $*")
}
info() { echo -e "  ${CYAN}→${RESET}  $*"; }
header() {
    CURRENT_TEST="$*"
    echo -e "\n${BOLD}${YELLOW}▶ $*${RESET}"
}

check_deps() {
    for cmd in dig unbound-control unbound-checkconf ss; do
        command -v "$cmd" &>/dev/null || { echo -e "${RED}Missing dependency: $cmd${RESET}"; exit 1; }
    done
}

# ── 1. Config check ──────────────────────────────────────────
test_config() {
    header "Config syntax check"
    if sudo unbound-checkconf 2>&1 | grep -q "no errors"; then
        pass "unbound-checkconf: no errors"
    else
        fail "unbound-checkconf reported issues:"
        sudo unbound-checkconf
    fi
}

# ── 2. Service status ────────────────────────────────────────
test_status() {
    header "Service status"
    if sudo unbound-control status 2>&1 | grep -q "is running"; then
        pass "Unbound is running"
    else
        fail "Unbound does not appear to be running"
        info "Try: sudo systemctl start unbound"
    fi
}

# ── 3. Listening on expected port ───────────────────────────
test_listening() {
    header "Network / listening check"
    if ss -tulnp 2>/dev/null | grep -q "unbound\|:53"; then
        pass "Unbound is listening on port 53"
        ss -tulnp | grep "unbound\|:53" | while read -r line; do
            info "$line"
        done
    else
        fail "Nothing detected on port 53 — Unbound may not be bound correctly"
    fi
}

# ── 4. Basic resolution ──────────────────────────────────────
test_basic_resolution() {
    header "Basic resolution  ($GOOD_DOMAIN @ $DNS_SERVER)"
    result=$(dig @"$DNS_SERVER" "$GOOD_DOMAIN" +short 2>/dev/null)
    if [[ -n "$result" ]]; then
        pass "Resolved $GOOD_DOMAIN:"
        echo "$result" | while read -r ip; do info "$ip"; done
    else
        fail "Could not resolve $GOOD_DOMAIN"
    fi
}

# ── 5. Caching (latency comparison) ─────────────────────────
test_caching() {
    header "Cache speed test  ($GOOD_DOMAIN)"
    t1=$(dig @"$DNS_SERVER" "$GOOD_DOMAIN" 2>/dev/null | awk '/Query time/ {print $4}')
    t2=$(dig @"$DNS_SERVER" "$GOOD_DOMAIN" 2>/dev/null | awk '/Query time/ {print $4}')
    info "First query:  ${t1} ms"
    info "Second query: ${t2} ms"
    if [[ -n "$t2" && "$t2" -lt "$t1" ]] 2>/dev/null; then
        pass "Cache is working (second query faster)"
    elif [[ "$t2" -eq 0 ]] 2>/dev/null; then
        pass "Cache is working (second query: 0 ms)"
    else
        info "Cache result inconclusive (timing may vary on fast networks)"
    fi
}

# ── 6. DNSSEC validation ─────────────────────────────────────
test_dnssec() {
    header "DNSSEC validation"

    # Should SERVFAIL for a deliberately broken domain
    rcode=$(dig @"$DNS_SERVER" "$DNSSEC_FAIL_DOMAIN" +short 2>/dev/null; \
            dig @"$DNS_SERVER" "$DNSSEC_FAIL_DOMAIN" 2>/dev/null | awk '/status:/ {print $6}' | tr -d ',')
    status=$(dig @"$DNS_SERVER" "$DNSSEC_FAIL_DOMAIN" 2>/dev/null | awk '/status:/ {print $6}' | tr -d ',')
    if [[ "$status" == "SERVFAIL" ]]; then
        pass "DNSSEC working — $DNSSEC_FAIL_DOMAIN correctly returned SERVFAIL"
    else
        fail "Expected SERVFAIL for $DNSSEC_FAIL_DOMAIN, got: ${status:-no response}"
        info "DNSSEC validation may not be enabled (check: val-permissive-mode: no)"
    fi

    # Good domain should carry the AD (Authenticated Data) flag
    ad_flag=$(dig @"$DNS_SERVER" "$GOOD_DOMAIN" +dnssec 2>/dev/null | awk '/flags:/ {print}')
    if echo "$ad_flag" | grep -q " ad"; then
        pass "AD flag present on $GOOD_DOMAIN — DNSSEC authenticated"
    else
        info "AD flag not set for $GOOD_DOMAIN (may be normal depending on trust anchor config)"
    fi
}

# ── 7. Blocklist check ───────────────────────────────────────
test_blocklist() {
    header "Blocklist / RPZ check  ($BLOCKED_DOMAIN)"
    result=$(dig @"$DNS_SERVER" "$BLOCKED_DOMAIN" +short 2>/dev/null)
    rcode=$(dig @"$DNS_SERVER" "$BLOCKED_DOMAIN" 2>/dev/null | awk '/status:/ {print $6}' | tr -d ',')
    if [[ "$rcode" == "NXDOMAIN" || "$result" == "0.0.0.0" || -z "$result" ]]; then
        pass "$BLOCKED_DOMAIN appears to be blocked (${rcode:-no answer})"
    else
        info "$BLOCKED_DOMAIN resolved to: $result"
        info "If you expected this domain to be blocked, check your blocklist config"
    fi
}

# ── 8. Stats snapshot ────────────────────────────────────────
test_stats() {
    header "Unbound stats snapshot"
    stats=$(sudo unbound-control stats_noreset 2>/dev/null)
    if [[ -n "$stats" ]]; then
        for key in total.num.queries total.num.cachehits total.num.cachemiss \
                   total.num.recursivereplies num.query.type.A num.query.type.AAAA; do
            val=$(echo "$stats" | grep "^${key}=" | cut -d= -f2)
            [[ -n "$val" ]] && info "${key}: ${val}"
        done
    else
        fail "Could not retrieve stats (is unbound-control configured?)"
    fi
}

# ── Main ─────────────────────────────────────────────────────
main() {
    echo -e "\n${BOLD}╔══════════════════════════════════════╗"
    echo    "║     Unbound DNS Test Suite           ║"
    echo -e "╚══════════════════════════════════════╝${RESET}"
    echo -e "  DNS server under test: ${CYAN}${DNS_SERVER}${RESET}"
    echo    "  Usage: $0 [dns-server-ip]"

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

    echo -e "\n${BOLD}╔══════════════════════════════════════╗"
    echo    "║            Test Summary              ║"
    echo -e "╚══════════════════════════════════════╝${RESET}"

    for result in "${SUMMARY_RESULTS[@]}"; do
        echo -e "  $result"
        if echo "$result" | grep -q "PASS"; then
            ((passes++))
        else
            ((failures++))
        fi
    done

    echo -e "\n  ${BOLD}Total: ${passes} passed, ${failures} failed${RESET}"
    if [[ "$failures" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All tests passed!${RESET}\n"
    else
        echo -e "  ${RED}${BOLD}${failures} test(s) need attention.${RESET}\n"
    fi
}

main "$@"
