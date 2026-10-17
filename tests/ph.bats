#!/usr/bin/env bats
# Tests for ph: Pi-hole administration over its v6 API, run against a
# mocked curl that records each request and answers from fixtures.

load test_helper

PH="${PROJECT_ROOT}/stow/personal/.local/bin/ph"

setup() {
    setup_tmpdir
    command -v jq >/dev/null || skip "jq is required"
    export HOME="${TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export PIHOLE_URL="https://pihole.test/admin/"
    export PIHOLE_PASSWORD="s3cret"
    export OSTYPE=linux-gnu
    FIX="${TEST_TMPDIR}/fix"
    CALLS="${TEST_TMPDIR}/calls"
    export FIX CALLS
    mkdir -p "${HOME}" "${FIX}" "${TEST_TMPDIR}/bin"
    : > "${CALLS}"
    printf '{"session":{"valid":true,"totp":false,"sid":"SID123","csrf":"x","validity":1800}}' > "${FIX}/POST_auth"
    # curl: logs METHOD PATH, the SID header and any body; answers with
    # FIX/<METHOD>_<path with / as _ and no query>, status from .code (200).
    cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET out=/dev/stdout fmt="" cfg="" body="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X) method="$2"; shift ;;
        -o) out="$2"; shift ;;
        -w) fmt="$2"; shift ;;
        -K) cfg="$2"; shift ;;
        --data-binary) body="$(cat)"; shift ;;
        -H|--max-time) shift ;;
        http*) url="$1" ;;
    esac
    shift
done
path="${url#https://pihole.test/api}"
sid=""
[[ -z "${cfg}" ]] || sid="$(sed -n 's/.*X-FTL-SID: \([^"]*\).*/\1/p' "${cfg}")"
printf '%s %s sid=%s body=%s\n' "${method}" "${path}" "${sid}" "${body}" >> "${CALLS}"
key="${path%%\?*}"; key="${method}_${key#/}"; key="${key//\//_}"
code=200
[[ ! -f "${FIX}/${key}.code" ]] || code="$(cat "${FIX}/${key}.code")"
if [[ -f "${FIX}/${key}" ]]; then cat "${FIX}/${key}" > "${out}"; else : > "${out}"; fi
[[ -z "${fmt}" ]] || printf '%s' "${code}"
EOF
    chmod +x "${TEST_TMPDIR}/bin/curl"
    export PATH="${TEST_TMPDIR}/bin:${PATH}"
}

teardown() {
    teardown_tmpdir
}

@test "ph: --help lists the commands" {
    run bash "${PH}" --help
    assert_success
    assert_output --partial "disable [DURATION]"
    assert_output --partial "blocked [CLIENT]"
}

@test "ph: unknown command or option fails" {
    run bash "${PH}" frobnicate
    assert_failure
    assert_output --partial "unknown command: frobnicate"
    run bash "${PH}" --bogus status
    assert_failure
    assert_output --partial "unknown option: --bogus"
}

@test "ph: logs in with the password on stdin and logs out on exit" {
    printf '{"blocking":"enabled","timer":null}' > "${FIX}/GET_dns_blocking"
    printf '{"queries":{"total":100,"blocked":25,"percent_blocked":25.0},"clients":{"active":3},"gravity":{"domains_being_blocked":5000,"last_update":0}}' > "${FIX}/GET_stats_summary"
    run bash "${PH}" status
    assert_success
    assert_output --partial "Blocking: enabled"
    assert_output --partial "Queries today: 100  blocked: 25 (25%)"
    assert_output --partial "domains on blocklists: 5000"
    run cat "${CALLS}"
    assert_line --index 0 'POST /auth sid= body={"password":"s3cret"}'
    assert_line --index 1 "GET /dns/blocking sid=SID123 body="
    assert_line --index 3 "DELETE /auth sid=SID123 body="
}

@test "ph: a wrong password fails with the reason and no logout" {
    printf '{"error":{"key":"unauthorized","message":"Unauthorized"}}' > "${FIX}/POST_auth"
    printf '401' > "${FIX}/POST_auth.code"
    run bash "${PH}" status
    assert_failure
    assert_output --partial "login failed: HTTP 401: wrong password"
    run grep -c . "${CALLS}"
    assert_output "1"
}

@test "ph: no password says to log in" {
    unset PIHOLE_PASSWORD
    run bash "${PH}" status
    assert_failure
    assert_output --partial "run 'ph login'"
}

@test "ph: the saved password file is used when PIHOLE_PASSWORD is unset" {
    unset PIHOLE_PASSWORD
    mkdir -p "${XDG_CONFIG_HOME}/ph"
    printf 'fromfile' > "${XDG_CONFIG_HOME}/ph/password"
    printf '{"blocking":"enabled","timer":null}' > "${FIX}/POST_dns_blocking"
    run bash "${PH}" enable
    assert_success
    run grep -c 'POST /auth sid= body={"password":"fromfile"}' "${CALLS}"
    assert_output "1"
}

@test "ph: disable with a duration sets a timer" {
    printf '{"blocking":"disabled","timer":300}' > "${FIX}/POST_dns_blocking"
    run bash "${PH}" disable 5m
    assert_success
    assert_output "Blocking: disabled (for 300s more)"
    run grep -c 'POST /dns/blocking sid=SID123 body={"blocking":false,"timer":300}' "${CALLS}"
    assert_output "1"
}

@test "ph: disable without a duration is permanent; a bad duration fails" {
    printf '{"blocking":"disabled","timer":null}' > "${FIX}/POST_dns_blocking"
    run bash "${PH}" disable
    assert_success
    run grep -c '"blocking":false,"timer":null' "${CALLS}"
    assert_output "1"
    run bash "${PH}" disable soon
    assert_failure
    assert_output --partial "bad duration: soon"
}

@test "ph: allow adds exact domains with a comment, regex with -r" {
    printf '{"processed":{"success":[{"item":"a.test"},{"item":"b.test"}],"errors":[]}}' > "${FIX}/POST_domains_allow_exact"
    run bash "${PH}" allow a.test b.test -c "work VPN"
    assert_success
    assert_line "Added to allow (exact): a.test"
    assert_line "Added to allow (exact): b.test"
    run grep -c 'POST /domains/allow/exact sid=SID123 body={"domain":\["a.test","b.test"\],"comment":"work VPN","enabled":true}' "${CALLS}"
    assert_output "1"
    printf '{"processed":{"success":[],"errors":[{"item":"(^|\\\\.)ads\\\\.","error":"UNIQUE constraint failed"}]}}' > "${FIX}/POST_domains_deny_regex"
    run bash "${PH}" deny -r '(^|\.)ads\.'
    assert_success
    assert_output --partial "Not added: (^|\\.)ads\\.: UNIQUE constraint failed"
}

@test "ph: whitelist is allow, block is deny" {
    run bash "${PH}" whitelist a.test
    assert_success
    run bash "${PH}" block b.test
    assert_success
    run grep -c 'POST /domains/allow/exact.*"a.test"' "${CALLS}"
    assert_output "1"
    run grep -c 'POST /domains/deny/exact.*"b.test"' "${CALLS}"
    assert_output "1"
}

@test "ph: undeny URL-encodes the domain in the path" {
    run bash "${PH}" undeny -r '^ad[0-9]+\.test$'
    assert_success
    assert_output --partial "Removed from deny (regex): ^ad[0-9]+\\.test\$"
    run grep -c 'DELETE /domains/deny/regex/%5Ead%5B0-9%5D%2B%5C.test%24 sid=SID123' "${CALLS}"
    assert_output "1"
}

@test "ph: an API error stops with its message" {
    printf '{"error":{"key":"not_found","message":"Item not found","hint":null}}' > "${FIX}/DELETE_domains_allow_exact_x.test"
    printf '404' > "${FIX}/DELETE_domains_allow_exact_x.test.code"
    run bash "${PH}" unallow x.test
    assert_failure
    assert_output --partial "HTTP 404: Item not found"
    run tail -1 "${CALLS}"
    assert_output --partial "DELETE /auth sid=SID123"
}

@test "ph: list shows both lists" {
    printf '{"domains":[{"domain":"b.test","type":"deny","kind":"exact","enabled":true,"comment":null},{"domain":"a.test","type":"allow","kind":"exact","enabled":false,"comment":"tv"}]}' > "${FIX}/GET_domains"
    run bash "${PH}" list
    assert_success
    assert_line --index 0 --regexp '^LIST +KIND +ON +DOMAIN +COMMENT$'
    assert_line --index 1 "allow  exact  no   a.test  tv"
    assert_line --index 2 "deny   exact  yes  b.test"
    run bash "${PH}" list everything
    assert_failure
}

@test "ph: blocked -a lists every query by client IP and strips control characters" {
    printf '{"queries":[{"time":1700000000.5,"type":"A","domain":"ads\\u001b[31m.test","status":"GRAVITY","client":{"ip":"192.168.1.20","name":"tv.lan"}}]}' > "${FIX}/GET_queries"
    run bash "${PH}" blocked -a 192.168.1.20 -n 5
    assert_success
    assert_line --index 1 --regexp '^[0-9-]+ [0-9:]+  tv\.lan  A     GRAVITY  ads\[31m\.test$'
    run grep -c 'GET /queries?length=5&upstream=blocklist&client_ip=192.168.1.20 ' "${CALLS}"
    assert_output "1"
}

@test "ph: blocked shows each domain once, newest first, over the last 24h" {
    local now
    now="$(date +%s)"
    NOW="${now}" perl -pe 's/NOW-(\d+)/$ENV{NOW} - $1/ge' > "${FIX}/GET_queries" <<'JSON'
{"queries":[
        {"time":NOW-300,"type":"A","domain":"old.test","status":"GRAVITY","client":{"ip":"10.0.0.1","name":null}},
        {"time":NOW-90,"type":"AAAA","domain":"ads.test","status":"GRAVITY","client":{"ip":"10.0.0.2","name":"tv.lan"}},
        {"time":NOW-200,"type":"A","domain":"ads.test","status":"DENYLIST","client":{"ip":"10.0.0.1","name":null}},
        {"time":NOW-7200,"type":"A","domain":"old.test","status":"GRAVITY","client":{"ip":"10.0.0.1","name":null}},
        {"time":NOW-90000,"type":"A","domain":"oldest.test","status":"REGEX","client":{"ip":"10.0.0.1","name":null}}]}
JSON
    run bash "${PH}" blocked -n 2
    assert_success
    assert_line --index 0 "3 domains blocked in the last 24h"
    assert_line --index 1 "LAST  HITS  WHY                   DOMAIN    CLIENTS"
    assert_line --index 2 "1m       2  blocklist, deny list  ads.test  10.0.0.1, tv.lan"
    assert_line --index 3 "5m       2  blocklist             old.test  10.0.0.1"
    assert_line --index 4 "1 more: ph blocked -n 3"
    run grep -cE 'GET /queries\?length=10000&upstream=blocklist&from=[0-9]+ ' "${CALLS}"
    assert_output "1"
}

@test "ph: blocked for one client drops the clients column; --since all has no time limit" {
    printf '{"queries":[]}' > "${FIX}/GET_queries"
    run bash "${PH}" blocked 10.0.0.1 --since all
    assert_success
    assert_output "Nothing blocked in the query log from 10.0.0.1."
    run grep -c 'GET /queries?length=10000&upstream=blocklist&client_ip=10.0.0.1 ' "${CALLS}"
    assert_output "1"
    run bash "${PH}" blocked --since soon
    assert_failure
    assert_output --partial "bad duration: soon"
}

@test "ph: queries by client name with a domain filter" {
    printf '{"queries":[]}' > "${FIX}/GET_queries"
    run bash "${PH}" queries tv.lan -d '*netflix*'
    assert_success
    assert_output "(no matching queries)"
    run grep -c 'GET /queries?length=25&client_name=tv.lan&domain=%2Anetflix%2A ' "${CALLS}"
    assert_output "1"
}

@test "ph: check reports list and blocklist matches" {
    printf '{"search":{"domains":[{"domain":"ads.test","type":"deny","kind":"exact","enabled":true,"comment":"mine"}],"gravity":[{"domain":"ads.test","address":"https://lists.test/hosts","type":"block"}]}}' > "${FIX}/GET_search_ads.test"
    run bash "${PH}" check ads.test
    assert_success
    assert_line "ads.test:"
    assert_line "  deny list (exact): ads.test  # mine"
    assert_line "  blocklist: https://lists.test/hosts"
    printf '{"search":{"domains":[],"gravity":[]}}' > "${FIX}/GET_search_ok.test"
    run bash "${PH}" check ok.test
    assert_output "ok.test: on no list, so not blocked"
}

@test "ph: a pasted URL is reduced to its host; a regex is left alone" {
    printf '{"search":{"domains":[],"gravity":[]}}' > "${FIX}/GET_search_mail.example.test"
    run bash "${PH}" check 'https://user:pw@mail.example.test:8443/mk/un/v2/sh/AbC?x=1#frag'
    assert_success
    assert_output "mail.example.test: on no list, so not blocked"
    run grep -c 'GET /search/mail.example.test?partial=false&N=20 sid=SID123' "${CALLS}"
    assert_output "1"
    run bash "${PH}" check 'https:///path'
    assert_failure
    assert_output "ph: no host in https:///path"
    printf '{"processed":{"success":[{"item":"a.test"},{"item":"b.test"}],"errors":[]}}' > "${FIX}/POST_domains_allow_exact"
    run bash "${PH}" allow 'http://a.test/x?y=z' b.test
    assert_success
    run grep -c 'POST /domains/allow/exact sid=SID123 body={"domain":\["a.test","b.test"\],"comment":null,"enabled":true}' "${CALLS}"
    assert_output "1"
    run bash "${PH}" undeny 'https://c.test/'
    assert_success
    assert_output --partial "Removed from deny (exact): c.test"
    run grep -c 'DELETE /domains/deny/exact/c.test sid=SID123' "${CALLS}"
    assert_output "1"
    run bash "${PH}" deny -r 'https?://ads\.'
    assert_success
    run grep -c 'POST /domains/deny/regex sid=SID123 body={"domain":\["https?://ads\\\\."\]' "${CALLS}"
    assert_output "1"
}

@test "ph: --json prints the API response" {
    printf '{"blocking":"enabled","timer":null}' > "${FIX}/POST_dns_blocking"
    run bash "${PH}" --json enable
    assert_success
    assert_output '{"blocking":"enabled","timer":null}'
}

@test "ph: api passes method, path, and body through" {
    printf '{"ok":true}' > "${FIX}/PATCH_config"
    run bash "${PH}" api patch /api/config '{"config":{}}'
    assert_success
    assert_output '{"ok":true}'
    run grep -c 'PATCH /config sid=SID123 body={"config":{}}' "${CALLS}"
    assert_output "1"
}
