#!/usr/bin/env bats
# Tests for the Pi-hole host scripts ph-sec-audit, ph-padd, ph-update, and ph-test, with their external commands mocked.

load test_helper

setup() {
    # Copies of the tools made by the tests find the shared helpers here.
    export DOTFILES_DIR="${PROJECT_ROOT}"
    setup_tmpdir
    export BIN_SANDBOX="${TEST_TMPDIR}/bin"
    mkdir -p "${BIN_SANDBOX}"
    cat > "${BIN_SANDBOX}/brew" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    --cache) printf '%s\n' "${TEST_TMPDIR}/brew-cache" ;;
    *) printf 'brew %s\n' "$*" ;;
esac
MOCK
    chmod +x "${BIN_SANDBOX}/brew"
}

teardown() {
    teardown_tmpdir
}

@test "ph-sec-audit defaults to a plan without applying changes" {
    run bash "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit"
    assert_success
    assert_output --partial "Without --apply"
    refute_output --partial "Backups:"

    run bash "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit" --upgrade-packages
    assert_success
    assert_output --partial "Without --apply"
    refute_output --partial "Backups:"
}

@test "ph-sec-audit requires a target and rejects malformed arguments" {
    run bash "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit" --apply
    assert_failure
    assert_output --partial "requires an explicit valid --user and --host"

    run bash "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit" --apply --user --host
    assert_failure
    assert_output --partial "Missing value"

    run bash "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit" --unknown
    assert_failure
    assert_output --partial "Unknown argument"
}

@test "ph-sec-audit refuses a different host before making changes" {
    run bash "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit" \
        --apply --user operator --host "$(hostname)-wrong-target"
    assert_failure
    assert_output --partial "Host mismatch; no changes made"
    refute_output --partial "Backups:"
}

run_remediation_web_probe() {
    local probe_script="${TEST_TMPDIR}/web-probe.sh"

    cat > "${probe_script}" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
old_ports='original-ports'
backup_dir="${TEST_TMPDIR}"
pihole-FTL() {
    printf '%s\n' "${3}" >> "${TEST_TMPDIR}/port-changes"
}
systemctl() {
    if [[ ! -f "${TEST_TMPDIR}/restart-attempted" ]]; then
        touch "${TEST_TMPDIR}/restart-attempted"
        case "${PROBE_FAILURE}" in
            restart) return 7 ;;
            interrupt) kill -TERM "$$" ;;
        esac
    fi
}
curl() { return 1; }
sleep() { :; }
PROBE
    awk '
        /^restore_web_ports\(\) \{/ { copy=1 }
        copy { print }
        /^trap - ERR HUP INT TERM$/ { exit }
    ' "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit" >> "${probe_script}"

    run env PROBE_FAILURE="${1}" bash "${probe_script}"
}

@test "ph-sec-audit restores web ports when verification fails" {
    run_remediation_web_probe verification
    assert_failure
    assert_output --partial "restoring original port configuration"
    run tail -n 1 "${TEST_TMPDIR}/port-changes"
    assert_success
    assert_output "original-ports"
}

@test "ph-sec-audit restores web ports and preserves restart failure status" {
    run_remediation_web_probe restart
    assert_equal "${status}" 7
    assert_output --partial "restoring original port configuration"
    run tail -n 1 "${TEST_TMPDIR}/port-changes"
    assert_success
    assert_output "original-ports"
}

@test "ph-sec-audit restores web ports when interrupted" {
    run_remediation_web_probe interrupt
    assert_equal "${status}" 143
    assert_output --partial "restoring original port configuration"
    run tail -n 1 "${TEST_TMPDIR}/port-changes"
    assert_success
    assert_output "original-ports"
}

# Runs ph-sec-audit's report_web_password with pihole-FTL answering $1.
run_web_password_probe() {
    local probe_script="${TEST_TMPDIR}/password-probe.sh"

    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
            'pihole-FTL() { printf "%s\n" "${PROBE_HASH}"; }'
        awk '
            /^report_web_password\(\) \{/ { copy=1 }
            copy { print }
            copy && /^}$/ { exit }
        ' "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-sec-audit"
        printf '%s\n' 'report_web_password'
    } > "${probe_script}"

    run env PROBE_HASH="${1}" bash "${probe_script}"
}

@test "ph-sec-audit reports whether a web password is set" {
    run_web_password_probe '$BALLOON-SHA256$v=1$fakehash'
    assert_success
    assert_output "A web password is set."

    run_web_password_probe '""'
    assert_success
    assert_output --partial "No web password is set"
    assert_output --partial "sudo pihole setpassword"

    run_web_password_probe ''
    assert_success
    assert_output --partial "No web password is set"
}

run_padd_api_probe() {
    local source_script="${1}"
    local probe_script="${TEST_TMPDIR}/$(basename "${source_script}")"

    awk '
        /^main\(\)\{$/ {
            print "main(){"
            print "    xOffset=0"
            print "    TestAPIAvailability"
            print "}"
            skip=1
            next
        }
        skip && /^}$/ {
            skip=0
            next
        }
        skip {
            next
        }
        { print }
    ' "${source_script}" > "${probe_script}"

    chmod +x "${probe_script}"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" "${probe_script}"
}

run_padd_dns_unbound_probe() {
    local source_script="${1}"
    local probe_script="${TEST_TMPDIR}/$(basename "${source_script}")"

    awk '
        /^main\(\)\{$/ {
            print "main(){"
            print "    connection_down_flag=true"
            print "    GetNetworkInformation"
            print "    printf '\''status=%s\\n'\'' \"${unbound_status}\""
            print "    printf '\''listener=%s\\n'\'' \"${unbound_listener}\""
            print "    printf '\''dnssec=%s\\n'\'' \"${unbound_dnssec_status}\""
            print "    printf '\''cache=%s\\n'\'' \"${unbound_cache_status}\""
            print "}"
            skip=1
            next
        }
        skip && /^}$/ {
            skip=0
            next
        }
        skip {
            next
        }
        { print }
    ' "${source_script}" > "${probe_script}"

    chmod +x "${probe_script}"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" "${probe_script}"
}

@test "ph-padd displays help" {
    run sh "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-padd" --help
    assert_success
    assert_output --partial "PADD displays stats about your Pi-hole"
    assert_output --partial "--api"
    assert_output --partial "--runonce"
}

@test "ph-padd startup probe fails fast when no API URLs are discovered" {
    cat > "${BIN_SANDBOX}/dig" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${TEST_TMPDIR}/ph-padd-dig-args"
exit 0
MOCK
    chmod +x "${BIN_SANDBOX}/dig"

    run_padd_api_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-padd"
    assert_failure
    assert_output --partial "API not available at: localhost"

    run cat "${TEST_TMPDIR}/ph-padd-dig-args"
    assert_success
    assert_output --partial "+time=2"
    assert_output --partial "+tries=1"
}

@test "ph-padd surfaces unbound listener and cache details" {
    local main_conf="${TEST_TMPDIR}/unbound.conf"
    local include_conf="${TEST_TMPDIR}/pi-hole.conf"

    cat > "${main_conf}" <<'CONF'
remote-control:
    control-enable: yes
CONF

    cat > "${include_conf}" <<'CONF'
server:
    interface: 127.0.0.1
    port: 5335
    harden-dnssec-stripped: yes
CONF

    cat > "${BIN_SANDBOX}/unbound-control" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        printf 'unbound is running as pid 1234\n'
        ;;
    stats_noreset)
        printf 'total.num.queries=200\n'
        printf 'total.num.cachehits=150\n'
        ;;
esac
MOCK

    chmod +x "${BIN_SANDBOX}/unbound-control"

    export PH_PADD_UNBOUND_MAIN_CONF="${main_conf}"
    export PH_PADD_UNBOUND_CONF="${include_conf}"

    run_padd_dns_unbound_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-padd"

    assert_success
    assert_output --partial "status=Running"
    assert_output --partial "listener=127.0.0.1:5335"
    assert_output --partial "dnssec=Hardened"
    assert_output --partial "cache=75% hit"

    unset PH_PADD_UNBOUND_MAIN_CONF
    unset PH_PADD_UNBOUND_CONF
}

@test "ph-padd does not splice unbound stats into awk code" {
    local marker="${TEST_TMPDIR}/awk-ran"

    cat > "${BIN_SANDBOX}/unbound-control" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    status) printf 'unbound is running as pid 1234\n' ;;
    stats_noreset)
        printf 'total.num.queries=2\n'
        printf 'total.num.cachehits=1) + system("touch ${marker}") + (1\n'
        ;;
esac
MOCK
    chmod +x "${BIN_SANDBOX}/unbound-control"

    PH_PADD_UNBOUND_MAIN_CONF="${TEST_TMPDIR}/missing.conf" \
        run_padd_dns_unbound_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-padd"

    assert_success
    assert_output --partial "cache=No stats"
    assert [ ! -e "${marker}" ]
}

# Replaces main() of a PADD script with the shell code in $PADD_PROBE_MAIN
# and runs it with the remaining arguments, with curl and dig mocked.
run_padd_main_probe() {
    local source_script="${1}"
    local probe_script
    probe_script="${TEST_TMPDIR}/probe-$(basename "${source_script}")"
    shift

    PADD_PROBE_MAIN="${PADD_PROBE_MAIN}" awk '
        /^main\(\)\{$/ { print "main(){"; print ENVIRON["PADD_PROBE_MAIN"]; print "}"; skip=1; next }
        skip && /^}$/ { skip=0; next }
        skip { next }
        { print }
    ' "${source_script}" > "${probe_script}"
    chmod +x "${probe_script}"

    rm -f "${TEST_TMPDIR}/curl-args" "${TEST_TMPDIR}/curl-stdin"
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" "${probe_script}" "$@"
}

# curl mock: logs argv and stdin separately and prints curl-body (plus the
# >>status suffix when called with -w). dig mock prints dig-reply.
write_padd_network_mocks() {
    ln -sf "$(command -v jq)" "${BIN_SANDBOX}/jq"

    cat > "${BIN_SANDBOX}/curl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMPDIR}/curl-args"
for arg in "\$@"; do
    case "\${arg}" in
        -|@-) cat >> "${TEST_TMPDIR}/curl-stdin"; printf '\n' >> "${TEST_TMPDIR}/curl-stdin" ;;
    esac
done
cat "${TEST_TMPDIR}/curl-body" 2>/dev/null
for arg in "\$@"; do
    [[ "\${arg}" == "-w" ]] && printf '>>200'
done
exit 0
MOCK

    cat > "${BIN_SANDBOX}/dig" <<MOCK
#!/usr/bin/env bash
cat "${TEST_TMPDIR}/dig-reply" 2>/dev/null
MOCK
    chmod +x "${BIN_SANDBOX}/curl" "${BIN_SANDBOX}/dig"
}

@test "ph-padd scripts never evaluate API numbers in shell arithmetic" {
    local marker="${TEST_TMPDIR}/pwned" script
    write_padd_network_mocks
    printf '{"system":{"uptime":"a[$(touch %s)]"}}' "${marker}" > "${TEST_TMPDIR}/curl-body"

    for script in ph-padd; do
        PADD_PROBE_MAIN='API_URL=https://127.0.0.1/api/; GetPADDData; convertUptime "$(GetPADDValue system.uptime)"; echo; convertUptime 90061' \
            run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}"
        assert_success
        assert_output --partial "0 days, 00 hours, 00 minutes"
        assert_output --partial "1 days, 01 hours, 01 minutes"
        assert [ ! -e "${marker}" ]
    done
}

@test "ph-padd scripts strip control characters from API strings" {
    local script
    write_padd_network_mocks
    printf '%s' '{"node_name":"evil\u001b]0;t\u0007\nsystem.uptime=5"}' > "${TEST_TMPDIR}/curl-body"

    for script in ph-padd; do
        PADD_PROBE_MAIN='API_URL=https://127.0.0.1/api/; GetPADDData; printf "host=%s|uptime=%s\n" "$(GetPADDValue node_name)" "$(GetPADDValue system.uptime)"' \
            run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}"
        assert_success
        assert_output "host=evil]0;tsystem.uptime=5|uptime="
    done
}

@test "ph-padd scripts verify TLS for remote servers and pin discovered URLs to --server" {
    local script
    write_padd_network_mocks
    printf '%s\n' '"https://attacker.example/api/" "http://attacker.example:80/api/"' > "${TEST_TMPDIR}/dig-reply"
    : > "${TEST_TMPDIR}/ca.pem"
    PADD_PROBE_MAIN='TestAPIAvailability; printf "api=%s\n" "${API_URL}"'

    for script in ph-padd; do
        run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --server 192.0.2.10
        assert_success
        assert_output --partial "api=https://192.0.2.10/api/"
        run cat "${TEST_TMPDIR}/curl-args"
        assert_output --partial "https://192.0.2.10/api/auth"
        refute_output --partial "--insecure"
        refute_output --regexp '(^| )-[a-zA-Z]*k'

        run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --server 192.0.2.10 --cacert "${TEST_TMPDIR}/ca.pem"
        assert_success
        run cat "${TEST_TMPDIR}/curl-args"
        assert_output --partial "--cacert ${TEST_TMPDIR}/ca.pem"
        refute_output --partial "--insecure"

        run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --server 192.0.2.10 --insecure
        assert_success
        run cat "${TEST_TMPDIR}/curl-args"
        assert_output --partial "--insecure"

        run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --server 127.0.0.1
        assert_success
        assert_output --partial "api=https://127.0.0.1/api/"
        run cat "${TEST_TMPDIR}/curl-args"
        assert_output --partial "--insecure"
    done
}

@test "ph-padd scripts refuse plain http API URLs for remote hosts" {
    local script
    write_padd_network_mocks
    printf '%s\n' '"http://attacker.example:80/api/"' > "${TEST_TMPDIR}/dig-reply"
    PADD_PROBE_MAIN='TestAPIAvailability; printf "api=%s\n" "${API_URL}"'

    for script in ph-padd; do
        run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --server 192.0.2.10
        assert_failure
        assert_output --partial "Refusing plain http:// API URL http://192.0.2.10:80/api/"
        assert [ ! -e "${TEST_TMPDIR}/curl-args" ]

        run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --api http://192.0.2.10/api/
        assert_failure
        assert_output --partial "Refusing API URL http://192.0.2.10/api/"
        assert [ ! -e "${TEST_TMPDIR}/curl-args" ]
    done
}

@test "ph-padd scripts keep the password and session ID out of curl argv" {
    local script
    write_padd_network_mocks
    printf '%s' '{"session":{"valid":true,"sid":"c2Vzc2lvbg=="}}' > "${TEST_TMPDIR}/curl-body"
    PADD_PROBE_MAIN='API_URL=https://192.0.2.10/api/; Authenticate; printf "valid=%s\n" "${validSession}"; GetFTLData info/ftl >/dev/null'

    for script in ph-padd; do
        PADD_PASSWORD='hunter2"\x' run_padd_main_probe "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}"
        assert_success
        assert_output --partial "valid=true"

        run cat "${TEST_TMPDIR}/curl-args"
        refute_output --partial "hunter2"
        refute_output --partial "c2Vzc2lvbg"

        run cat "${TEST_TMPDIR}/curl-stdin"
        assert_output --partial '{"password":"hunter2\"\\x","totp":null}'
        assert_output --partial 'header = "sid: c2Vzc2lvbg=="'
    done
}

@test "ph-padd scripts reject --secret and skip self-update" {
    local script

    for script in ph-padd; do
        run sh "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --secret hunter2
        assert_failure
        assert_output --partial "PADD_PASSWORD"

        # -u never downloads: the file comes from the repo
        run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" sh "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --update
        assert_success
        assert_output "ph-padd is managed by ~/.dotfiles; update it there."

        run sh "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/${script}" --help
        assert_output --partial "--cacert"
        assert_output --partial "--insecure"
        refute_output --partial "--secret"
    done
}

@test "ph-update displays help" {
    run "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "ph-update"
    assert_output --partial "ph-update -r"
    assert_output --partial "Run os-doctor, refresh Pi-hole, and optionally restart Linux"
}

@test "ph-update runs os-doctor before self-elevating through sudo" {
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/pihole" <<'MOCK'
#!/usr/bin/env bash
printf 'pihole %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/ph-padd" <<'MOCK'
#!/usr/bin/env bash
printf 'ph-padd %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/apt-get" "${BIN_SANDBOX}/pihole" "${BIN_SANDBOX}/ph-padd"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update"
    assert_success
    assert_output --partial "sudo apt-get update"
    refute_output --partial "PATH="
    assert_output --partial "sudo PH_UPDATE_SKIP_OS_UPDATE=1 ${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update"
}

@test "ph-update preserves -r through self-elevating sudo" {
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/pihole" <<'MOCK'
#!/usr/bin/env bash
printf 'pihole %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/ph-padd" <<'MOCK'
#!/usr/bin/env bash
printf 'ph-padd %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/apt-get" "${BIN_SANDBOX}/pihole" "${BIN_SANDBOX}/ph-padd"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update" -r
    assert_success
    assert_output --partial "PH_UPDATE_SKIP_OS_UPDATE=1"
    assert_output --partial "ph-update -r"
}

@test "ph-update rejects -r on non-linux hosts" {
    run env OSTYPE="darwin23" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update" -r
    assert_failure
    assert_output --partial "-r/--restart is only supported on Linux"
}

@test "ph-update restarts Linux after a successful run when -r is set" {
    local probe_script="${TEST_TMPDIR}/ph-update"
    ln -sf "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor" "${TEST_TMPDIR}/os-doctor"

    sed 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update" > "${probe_script}"
    chmod +x "${probe_script}"

    cat > "${BIN_SANDBOX}/pihole" <<'MOCK'
#!/usr/bin/env bash
printf 'pihole %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/ph-padd" <<'MOCK'
#!/usr/bin/env bash
printf 'ph-padd %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/shutdown" <<'MOCK'
#!/usr/bin/env bash
printf 'shutdown %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/pihole" "${BIN_SANDBOX}/ph-padd" "${BIN_SANDBOX}/shutdown"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" PH_UPDATE_SKIP_OS_UPDATE=1 \
        DOTFILES_DIR="${PROJECT_ROOT}" "${probe_script}" -r
    assert_success
    assert_output --partial "Pi-hole update and gravity refresh completed"
    assert_output --partial "shutdown -r now"
}

@test "ph-update -r does not restart Linux when the Pi-hole update fails" {
    local probe_script="${TEST_TMPDIR}/ph-update"
    ln -sf "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor" "${TEST_TMPDIR}/os-doctor"
    sed 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update" > "${probe_script}"
    chmod +x "${probe_script}"

    # The update runs; the gravity refresh after it fails.
    cat > "${BIN_SANDBOX}/pihole" <<'MOCK'
#!/usr/bin/env bash
printf 'pihole %s\n' "$*"
[[ "$1" != -f ]]
MOCK
    printf '#!/usr/bin/env bash\n' > "${BIN_SANDBOX}/ph-padd"
    printf '#!/usr/bin/env bash\nprintf "shutdown %%s\\n" "$*" >> "%s/shutdown.log"\n' "${TEST_TMPDIR}" > "${BIN_SANDBOX}/shutdown"
    chmod +x "${BIN_SANDBOX}/pihole" "${BIN_SANDBOX}/ph-padd" "${BIN_SANDBOX}/shutdown"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" PH_UPDATE_SKIP_OS_UPDATE=1 \
        DOTFILES_DIR="${PROJECT_ROOT}" "${probe_script}" -r
    assert_failure
    assert_output --partial "pihole -up"
    assert_output --partial "Pi-hole update or gravity refresh failed"
    refute_output --partial "Running shutdown -r now"
    [ ! -e "${TEST_TMPDIR}/shutdown.log" ]
}

@test "ph-update fails before os-doctor when pihole is unavailable" {
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/apt-get"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update"
    assert_failure
    assert_output --partial "pihole command is unavailable"
    [[ "${output}" != *"sudo apt-get update"* ]]
}

@test "ph-update as root searches only system directories, not the caller's PATH" {
    local probe_script="${TEST_TMPDIR}/ph-update"

    [[ ! -e /usr/local/bin/pihole && ! -e /usr/bin/pihole ]] || skip "pihole is installed on this host"

    # Take the root branch without being root; stay out of os-doctor and sudo.
    sed -e 's/^if (( EUID == 0 )); then$/if true; then/' \
        -e 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-update" > "${probe_script}"
    chmod +x "${probe_script}"

    local cmd
    for cmd in pihole ph-padd shutdown gum; do
        printf '#!/usr/bin/env bash\ntouch "%s/user-path-used"\n' "${TEST_TMPDIR}" > "${BIN_SANDBOX}/${cmd}"
        chmod +x "${BIN_SANDBOX}/${cmd}"
    done

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" PH_UPDATE_SKIP_OS_UPDATE=1 \
        DOTFILES_DIR="${PROJECT_ROOT}" "${probe_script}"
    assert_failure
    assert_output --partial "pihole command is unavailable"
    [[ ! -e "${TEST_TMPDIR}/user-path-used" ]]
}

@test "ph-test displays help" {
    run "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "ph-test [dns-server-ip]"
    assert_output --partial "Defaults to 127.0.0.1"
}

@test "ph-test self-elevates through sudo and preserves dns server arg" {
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK
    chmod +x "${BIN_SANDBOX}/sudo"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test" 192.0.2.53
    assert_success
    refute_output --partial "PATH="
    assert_output --partial "sudo ${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test 192.0.2.53"
}

@test "ph-test finds unbound commands through supplemental sbin paths" {
    local unbound_sbin="${TEST_TMPDIR}/unbound-sbin"
    mkdir -p "${unbound_sbin}"

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

script_path="${1}"
shift

tmp_script="$(mktemp)"
awk '
    /^# Self-elevate if not root/ { skip=1; next }
    skip && /^DNS_SERVER=/ { skip=0 }
    !skip {
        if ($0 == "main \"$@\"") {
            print "check_deps"
            exit
        }
        print
    }
' "${script_path}" > "${tmp_script}"

chmod +x "${tmp_script}"
exec "${tmp_script}" "$@"
MOCK

    cat > "${BIN_SANDBOX}/dig" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${BIN_SANDBOX}/ss" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${unbound_sbin}/unbound-checkconf" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-o" && "${2:-}" == "config-file" ]]; then
    printf '/etc/unbound/unbound.conf\n'
fi
exit 0
MOCK

    cat > "${unbound_sbin}/unbound-control" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x \
        "${BIN_SANDBOX}/sudo" \
        "${BIN_SANDBOX}/dig" \
        "${BIN_SANDBOX}/ss" \
        "${unbound_sbin}/unbound-checkconf" \
        "${unbound_sbin}/unbound-control"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" PH_TEST_SBIN_PATHS="${unbound_sbin}" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
    assert_success
    [[ "${output}" != *"Missing dependency: unbound-control"* ]]
    [[ "${output}" != *"Missing dependency: unbound-checkconf"* ]]
}

@test "ph-test prefers Pi-hole include settings and falls back to unbound.conf" {
    local primary_conf="${TEST_TMPDIR}/pi-hole.conf"
    local main_conf="${TEST_TMPDIR}/unbound.conf"

    cat > "${primary_conf}" <<'CONF'
server:
    interface: 127.0.0.1
CONF

    cat > "${main_conf}" <<'CONF'
server:
    interface: 0.0.0.0
    hide-version: yes
CONF

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

script_path="${1}"
shift

tmp_script="$(mktemp)"
awk '
    /^# Self-elevate if not root/ { skip=1; next }
    skip && /^DNS_SERVER=/ { skip=0 }
    !skip {
        if ($0 == "main \"$@\"") {
            print "printf '\''UNBOUND_CONF=%s\\n'\'' \"${UNBOUND_CONF}\""
            print "printf '\''interface=%s\\n'\'' \"$(get_unbound_setting interface)\""
            print "printf '\''hide-version=%s\\n'\'' \"$(get_unbound_setting hide-version)\""
            exit
        }
        print
    }
' "${script_path}" > "${tmp_script}"

chmod +x "${tmp_script}"
exec "${tmp_script}" "$@"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo"

    run env \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        PH_TEST_UNBOUND_CONF="${primary_conf}" \
        PH_TEST_UNBOUND_MAIN_CONF="${main_conf}" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
    assert_success
    assert_output --partial "UNBOUND_CONF=${primary_conf}"
    assert_output --partial "interface=127.0.0.1"
    assert_output --partial "hide-version=yes"
}

@test "ph-test requests AD explicitly and prints a direct-fix tip when AD is hidden" {
    local conf_file="${TEST_TMPDIR}/unbound.conf"
    local dig_log="${TEST_TMPDIR}/dig.log"

    cat > "${conf_file}" <<'CONF'
server:
    interface: 127.0.0.1
    port: 5335
CONF

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

script_path="${1}"
shift

tmp_script="$(mktemp)"
awk '
    /^# Self-elevate if not root/ { skip=1; next }
    skip && /^DNS_SERVER=/ { skip=0 }
    /^main\(\) \{$/ {
        print "main() {"
        print "    init_pihole_vars"
        print "    test_dnssec"
        print "    flush_section"
        print "    print_summary"
        print "}"
        in_main=1
        next
    }
    in_main && /^}$/ {
        in_main=0
        next
    }
    !skip && !in_main {
        print
    }
' "${script_path}" > "${tmp_script}"

chmod +x "${tmp_script}"
exec "${tmp_script}" "$@"
MOCK

    cat > "${BIN_SANDBOX}/dig" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PH_TEST_DIG_LOG}"

if [[ "$*" == *"dnssec-failed.org"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1
OUT
    exit 0
fi

if [[ "$*" == *"cloudflare.com"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; flags: qr rd ra; QUERY: 1, ANSWER: 1
OUT
    exit 0
fi

exit 0
MOCK

    cat > "${BIN_SANDBOX}/pgrep" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-x" && "${2:-}" == "pihole-FTL" ]]; then
    exit 0
fi
exit 1
MOCK

    cat > "${BIN_SANDBOX}/find" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x \
        "${BIN_SANDBOX}/sudo" \
        "${BIN_SANDBOX}/dig" \
        "${BIN_SANDBOX}/pgrep" \
        "${BIN_SANDBOX}/find"

    run env \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        PH_TEST_DIG_LOG="${dig_log}" \
        PH_TEST_UNBOUND_CONF="${conf_file}" \
        PH_TEST_UNBOUND_MAIN_CONF="${conf_file}" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
    assert_success
    assert_output --partial "AD flag not exposed on direct query to 127.0.0.1:5335"
    assert_output --partial "Re-test the direct resolver socket: dig @127.0.0.1 -p 5335 cloudflare.com +dnssec +adflag"

    run cat "${dig_log}"
    assert_success
    assert_output --partial "@127.0.0.1 -p 5335 cloudflare.com +dnssec +adflag"
    refute_output --partial "google.com +dnssec"
}

# run_with_timeout polls its command once a second; a fifth of a second per
# tick keeps a 5s budget at 1s of real time.
stub_ph_test_sleep() {
    printf '#!/bin/sh\nexec /bin/sleep 0.2\n' > "${BIN_SANDBOX}/sleep"
    chmod +x "${BIN_SANDBOX}/sleep"
}

@test "ph-test still prints summary when stats collection fails" {
    stub_ph_test_sleep
    local conf_file="${TEST_TMPDIR}/unbound.conf"

    cat > "${conf_file}" <<'CONF'
server:
    interface: 127.0.0.1
    hide-version: yes
    hide-identity: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
CONF

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == */ph-test ]]; then
    script_path="${1}"
    shift

    tmp_script="$(mktemp)"
    awk '
        /^# Self-elevate if not root/ { skip=1; next }
        skip && /^DNS_SERVER=/ { skip=0 }
        !skip {
            print
        }
    ' "${script_path}" > "${tmp_script}"

    chmod +x "${tmp_script}"
    exec "${tmp_script}" "$@"
fi

exec "$@"
MOCK

    cat > "${BIN_SANDBOX}/unbound-checkconf" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-o" && "${2:-}" == "config-file" ]]; then
    printf '%s\n' "${PH_TEST_UNBOUND_MAIN_CONF}"
    exit 0
fi

printf 'no errors\n'
MOCK

    cat > "${BIN_SANDBOX}/unbound-control" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        printf 'version 1.0\n'
        printf 'daemon is running\n'
        ;;
    stats_noreset)
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/ss" <<'MOCK'
#!/usr/bin/env bash
printf 'udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:* users:(("unbound",pid=1,fd=3))\n'
MOCK

    cat > "${BIN_SANDBOX}/dig" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"google.com +short"* ]]; then
    printf '142.250.190.14\n'
    exit 0
fi

if [[ "$*" == *"cloudflare.com +dnssec"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; flags: qr rd ra; QUERY: 1, ANSWER: 1
OUT
    exit 0
fi

if [[ "$*" == *"dnssec-failed.org"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1
OUT
    exit 0
fi

if [[ "$*" == *"doubleclick.net"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1
OUT
    exit 0
fi

cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; Query time: 12 msec
OUT
MOCK

    cat > "${BIN_SANDBOX}/ps" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${BIN_SANDBOX}/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "unbound" ]]; then
    exit 0
fi
exit 1
MOCK

    cat > "${BIN_SANDBOX}/getent" <<'MOCK'
#!/usr/bin/env bash
if [[ "${2:-}" == "unbound" ]]; then
    exit 0
fi
exit 1
MOCK

    cat > "${BIN_SANDBOX}/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    is-enabled)
        exit 0
        ;;
    is-active)
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "%U:%G" ]]; then
    printf 'root:root\n'
elif [[ "${1:-}" == "-c" && "${2:-}" == "%a" ]]; then
    printf '755\n'
fi
MOCK

    cat > "${BIN_SANDBOX}/pgrep" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK

    cat > "${BIN_SANDBOX}/find" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x \
        "${BIN_SANDBOX}/sudo" \
        "${BIN_SANDBOX}/unbound-checkconf" \
        "${BIN_SANDBOX}/unbound-control" \
        "${BIN_SANDBOX}/ss" \
        "${BIN_SANDBOX}/dig" \
        "${BIN_SANDBOX}/ps" \
        "${BIN_SANDBOX}/id" \
        "${BIN_SANDBOX}/getent" \
        "${BIN_SANDBOX}/systemctl" \
        "${BIN_SANDBOX}/stat" \
        "${BIN_SANDBOX}/pgrep" \
        "${BIN_SANDBOX}/find"

    run env \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        PH_TEST_UNBOUND_CONF="${conf_file}" \
        PH_TEST_UNBOUND_MAIN_CONF="${conf_file}" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
    assert_failure
    assert_output --partial "Summary"
    assert_output --partial "Could not retrieve stats"
    assert_output --partial "Found 1 failing check(s)."
}

@test "ph-test times out hung stats collection and still prints summary" {
    stub_ph_test_sleep
    local conf_file="${TEST_TMPDIR}/unbound.conf"

    cat > "${conf_file}" <<'CONF'
server:
    interface: 127.0.0.1
    hide-version: yes
    hide-identity: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
CONF

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == */ph-test ]]; then
    script_path="${1}"
    shift

    tmp_script="$(mktemp)"
    awk '
        /^# Self-elevate if not root/ { skip=1; next }
        skip && /^DNS_SERVER=/ { skip=0 }
        !skip {
            print
        }
    ' "${script_path}" > "${tmp_script}"

    chmod +x "${tmp_script}"
    exec "${tmp_script}" "$@"
fi

exec "$@"
MOCK

    cat > "${BIN_SANDBOX}/unbound-checkconf" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-o" && "${2:-}" == "config-file" ]]; then
    printf '%s\n' "${PH_TEST_UNBOUND_MAIN_CONF}"
    exit 0
fi

printf 'no errors\n'
MOCK

    cat > "${BIN_SANDBOX}/unbound-control" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        printf 'version 1.0\n'
        printf 'daemon is running\n'
        ;;
    stats_noreset)
        exec /bin/sleep 5
        ;;
    *)
        exit 0
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/ss" <<'MOCK'
#!/usr/bin/env bash
printf 'udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:* users:(("unbound",pid=1,fd=3))\n'
MOCK

    cat > "${BIN_SANDBOX}/dig" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"google.com +short"* ]]; then
    printf '142.250.190.14\n'
    exit 0
fi

if [[ "$*" == *"cloudflare.com +dnssec"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; flags: qr rd ra; QUERY: 1, ANSWER: 1
OUT
    exit 0
fi

if [[ "$*" == *"dnssec-failed.org"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1
OUT
    exit 0
fi

if [[ "$*" == *"doubleclick.net"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1
OUT
    exit 0
fi

cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; Query time: 12 msec
OUT
MOCK

    cat > "${BIN_SANDBOX}/ps" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${BIN_SANDBOX}/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "unbound" ]]; then
    exit 0
fi
exit 1
MOCK

    cat > "${BIN_SANDBOX}/getent" <<'MOCK'
#!/usr/bin/env bash
if [[ "${2:-}" == "unbound" ]]; then
    exit 0
fi
exit 1
MOCK

    cat > "${BIN_SANDBOX}/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    is-enabled)
        exit 0
        ;;
    is-active)
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "%U:%G" ]]; then
    printf 'root:root\n'
elif [[ "${1:-}" == "-c" && "${2:-}" == "%a" ]]; then
    printf '755\n'
fi
MOCK

    cat > "${BIN_SANDBOX}/pgrep" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK

    cat > "${BIN_SANDBOX}/find" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x \
        "${BIN_SANDBOX}/sudo" \
        "${BIN_SANDBOX}/unbound-checkconf" \
        "${BIN_SANDBOX}/unbound-control" \
        "${BIN_SANDBOX}/ss" \
        "${BIN_SANDBOX}/dig" \
        "${BIN_SANDBOX}/ps" \
        "${BIN_SANDBOX}/id" \
        "${BIN_SANDBOX}/getent" \
        "${BIN_SANDBOX}/systemctl" \
        "${BIN_SANDBOX}/stat" \
        "${BIN_SANDBOX}/pgrep" \
        "${BIN_SANDBOX}/find"

    run env \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        PH_TEST_TIMEOUT_SECONDS=1 \
        PH_TEST_UNBOUND_CONF="${conf_file}" \
        PH_TEST_UNBOUND_MAIN_CONF="${conf_file}" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
    assert_failure
    assert_output --partial "Summary"
    assert_output --partial "Could not retrieve stats (timed out after 1s)"
    assert_output --partial "Found 1 failing check(s)."
}

@test "ph-test still prints summary when stats output omits some keys" {
    stub_ph_test_sleep
    local conf_file="${TEST_TMPDIR}/unbound.conf"

    cat > "${conf_file}" <<'CONF'
server:
    interface: 127.0.0.1
    hide-version: yes
    hide-identity: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
CONF

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == */ph-test ]]; then
    script_path="${1}"
    shift

    tmp_script="$(mktemp)"
    awk '
        /^# Self-elevate if not root/ { skip=1; next }
        skip && /^DNS_SERVER=/ { skip=0 }
        !skip {
            print
        }
    ' "${script_path}" > "${tmp_script}"

    chmod +x "${tmp_script}"
    exec "${tmp_script}" "$@"
fi

exec "$@"
MOCK

    cat > "${BIN_SANDBOX}/unbound-checkconf" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-o" && "${2:-}" == "config-file" ]]; then
    printf '%s\n' "${PH_TEST_UNBOUND_MAIN_CONF}"
    exit 0
fi

printf 'no errors\n'
MOCK

    cat > "${BIN_SANDBOX}/unbound-control" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        printf 'version 1.0\n'
        printf 'daemon is running\n'
        ;;
    stats_noreset)
        cat <<'OUT'
total.num.queries=42
total.num.cachehits=10
OUT
        ;;
    *)
        exit 0
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/ss" <<'MOCK'
#!/usr/bin/env bash
printf 'udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:* users:(("unbound",pid=1,fd=3))\n'
MOCK

    cat > "${BIN_SANDBOX}/dig" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"google.com +short"* ]]; then
    printf '142.250.190.14\n'
    exit 0
fi

if [[ "$*" == *"cloudflare.com +dnssec"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; flags: qr rd ra; QUERY: 1, ANSWER: 1
OUT
    exit 0
fi

if [[ "$*" == *"dnssec-failed.org"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1
OUT
    exit 0
fi

if [[ "$*" == *"doubleclick.net"* ]]; then
    cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1
OUT
    exit 0
fi

cat <<'OUT'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; Query time: 12 msec
OUT
MOCK

    cat > "${BIN_SANDBOX}/ps" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${BIN_SANDBOX}/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "unbound" ]]; then
    exit 0
fi
exit 1
MOCK

    cat > "${BIN_SANDBOX}/getent" <<'MOCK'
#!/usr/bin/env bash
if [[ "${2:-}" == "unbound" ]]; then
    exit 0
fi
exit 1
MOCK

    cat > "${BIN_SANDBOX}/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    is-enabled)
        exit 0
        ;;
    is-active)
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "%U:%G" ]]; then
    printf 'root:root\n'
elif [[ "${1:-}" == "-c" && "${2:-}" == "%a" ]]; then
    printf '755\n'
fi
MOCK

    cat > "${BIN_SANDBOX}/pgrep" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK

    cat > "${BIN_SANDBOX}/find" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x \
        "${BIN_SANDBOX}/sudo" \
        "${BIN_SANDBOX}/unbound-checkconf" \
        "${BIN_SANDBOX}/unbound-control" \
        "${BIN_SANDBOX}/ss" \
        "${BIN_SANDBOX}/dig" \
        "${BIN_SANDBOX}/ps" \
        "${BIN_SANDBOX}/id" \
        "${BIN_SANDBOX}/getent" \
        "${BIN_SANDBOX}/systemctl" \
        "${BIN_SANDBOX}/stat" \
        "${BIN_SANDBOX}/pgrep" \
        "${BIN_SANDBOX}/find"

    run env \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        PH_TEST_UNBOUND_CONF="${conf_file}" \
        PH_TEST_UNBOUND_MAIN_CONF="${conf_file}" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
    assert_success
    assert_output --partial "Summary"
    assert_output --partial "total.num.queries: 42"
    assert_output --partial "Passed:"
}

@test "ph-test as root searches only system directories, not the caller's PATH" {
    local probe_script="${TEST_TMPDIR}/ph-test"
    local dir

    for dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
        [[ ! -e "${dir}/unbound-control" ]] || skip "unbound is installed on this host"
    done

    # Take the root branch without being root.
    sed 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test" > "${probe_script}"
    chmod +x "${probe_script}"

    local cmd
    for cmd in dig unbound-control unbound-checkconf ss gum sudo; do
        printf '#!/usr/bin/env bash\ntouch "%s/user-path-used"\n' "${TEST_TMPDIR}" > "${BIN_SANDBOX}/${cmd}"
        chmod +x "${BIN_SANDBOX}/${cmd}"
    done

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" "${probe_script}"
    assert_failure
    assert_output --partial "Missing dependency: unbound-control"
    [[ ! -e "${TEST_TMPDIR}/user-path-used" ]]
}
