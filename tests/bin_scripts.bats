#!/usr/bin/env bats
# Tests for the stow/*/.local/bin scripts — isolated smoke and behavior coverage.

load test_helper

setup() {
    setup_tmpdir
    export BIN_SANDBOX="${TEST_TMPDIR}/bin"
    mkdir -p "${BIN_SANDBOX}"
    ln -sf "$(brew --prefix)/bin/bash" "${BIN_SANDBOX}/bash"
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
    run bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-sec-audit"
    assert_success
    assert_output --partial "Without --apply"
    refute_output --partial "Backups:"

    run bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-sec-audit" --upgrade-packages
    assert_success
    assert_output --partial "Without --apply"
    refute_output --partial "Backups:"
}

@test "ph-sec-audit requires a target and rejects malformed arguments" {
    run bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-sec-audit" --apply
    assert_failure
    assert_output --partial "requires an explicit valid --user and --host"

    run bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-sec-audit" --apply --user --host
    assert_failure
    assert_output --partial "Missing value"

    run bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-sec-audit" --unknown
    assert_failure
    assert_output --partial "Unknown argument"
}

@test "ph-sec-audit refuses a different host before making changes" {
    run bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-sec-audit" \
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
    ' "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-sec-audit" >> "${probe_script}"

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
    run sh "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-padd" --help
    assert_success
    assert_output --partial "PADD displays stats about your Pi-hole"
    assert_output --partial "--api"
    assert_output --partial "--runonce"
}

@test "ph-padd-dns displays help" {
    run sh "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-padd-dns" --help
    assert_success
    assert_output --partial "Unbound resolver details"
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

    run_padd_api_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-padd"
    assert_failure
    assert_output --partial "API not available at: localhost"

    run cat "${TEST_TMPDIR}/ph-padd-dig-args"
    assert_success
    assert_output --partial "+time=2"
    assert_output --partial "+tries=1"
}

@test "ph-padd-dns surfaces unbound listener and cache details" {
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

    export PH_PADD_DNS_UNBOUND_MAIN_CONF="${main_conf}"
    export PH_PADD_DNS_UNBOUND_CONF="${include_conf}"

    run_padd_dns_unbound_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-padd-dns"

    assert_success
    assert_output --partial "status=Running"
    assert_output --partial "listener=127.0.0.1:5335"
    assert_output --partial "dnssec=Hardened"
    assert_output --partial "cache=75% hit"

    unset PH_PADD_DNS_UNBOUND_MAIN_CONF
    unset PH_PADD_DNS_UNBOUND_CONF
}

@test "ph-padd-dns does not splice unbound stats into awk code" {
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

    PH_PADD_DNS_UNBOUND_MAIN_CONF="${TEST_TMPDIR}/missing.conf" \
        run_padd_dns_unbound_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-padd-dns"

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

    for script in ph-padd ph-padd-dns; do
        PADD_PROBE_MAIN='API_URL=https://127.0.0.1/api/; GetPADDData; convertUptime "$(GetPADDValue system.uptime)"; echo; convertUptime 90061' \
            run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}"
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

    for script in ph-padd ph-padd-dns; do
        PADD_PROBE_MAIN='API_URL=https://127.0.0.1/api/; GetPADDData; printf "host=%s|uptime=%s\n" "$(GetPADDValue node_name)" "$(GetPADDValue system.uptime)"' \
            run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}"
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

    for script in ph-padd ph-padd-dns; do
        run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --server 192.0.2.10
        assert_success
        assert_output --partial "api=https://192.0.2.10/api/"
        run cat "${TEST_TMPDIR}/curl-args"
        assert_output --partial "https://192.0.2.10/api/auth"
        refute_output --partial "--insecure"
        refute_output --regexp '(^| )-[a-zA-Z]*k'

        run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --server 192.0.2.10 --cacert "${TEST_TMPDIR}/ca.pem"
        assert_success
        run cat "${TEST_TMPDIR}/curl-args"
        assert_output --partial "--cacert ${TEST_TMPDIR}/ca.pem"
        refute_output --partial "--insecure"

        run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --server 192.0.2.10 --insecure
        assert_success
        run cat "${TEST_TMPDIR}/curl-args"
        assert_output --partial "--insecure"

        run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --server 127.0.0.1
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

    for script in ph-padd ph-padd-dns; do
        run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --server 192.0.2.10
        assert_failure
        assert_output --partial "Refusing plain http:// API URL http://192.0.2.10:80/api/"
        assert [ ! -e "${TEST_TMPDIR}/curl-args" ]

        run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --api http://192.0.2.10/api/
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

    for script in ph-padd ph-padd-dns; do
        PADD_PASSWORD='hunter2"\x' run_padd_main_probe "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}"
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

    for script in ph-padd ph-padd-dns; do
        run sh "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --secret hunter2
        assert_failure
        assert_output --partial "PADD_PASSWORD"

        # ph-update still calls -u, so it succeeds without downloading anything
        run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" sh "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --update
        assert_success
        assert_output "ph-padd is managed by ~/.dotfiles; update it there."

        run sh "${PROJECT_ROOT}/stow/server.linux/.local/bin/${script}" --help
        assert_output --partial "--cacert"
        assert_output --partial "--insecure"
        refute_output --partial "--secret"
    done
}

@test "os-update displays help" {
    run "${PROJECT_ROOT}/stow/tools/.local/bin/os-update" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "os-update"
    assert_output --partial "package-manager updates"
}

@test "os-update runs linux apt and Homebrew updates" {
    mkdir -p "${TEST_TMPDIR}/.cache/Homebrew"

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/brew" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--cache" ]]; then
    printf '%s\n' "${TEST_TMPDIR}/.cache/Homebrew"
    exit 0
fi

printf 'brew %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/apt-get" "${BIN_SANDBOX}/brew"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-update"
    assert_success
    assert_output --partial "sudo apt-get update"
    assert_output --partial "sudo apt-get full-upgrade -y"
    assert_output --partial "sudo apt-get autoremove --purge -y"
    assert_output --partial "sudo apt-get autoclean -y"
    assert_output --partial "brew update"
    assert_output --partial "brew upgrade"
    assert_output --partial "brew cleanup --prune=all"
    [[ ! -d "${TEST_TMPDIR}/.cache/Homebrew" ]]
}

@test "os-update runs macOS system and Homebrew updates" {
    mkdir -p "${TEST_TMPDIR}/Applications/Xcode.app"
    mkdir -p "${TEST_TMPDIR}/Library/Caches/Homebrew"

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/softwareupdate" <<'MOCK'
#!/usr/bin/env bash
printf 'softwareupdate %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/brew" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--cache" ]]; then
    printf '%s\n' "${TEST_TMPDIR}/Library/Caches/Homebrew"
    exit 0
fi

printf 'brew %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/mas" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    outdated)
        printf '123456 Example App (1.0 -> 1.1)\n'
        ;;
    upgrade)
        printf 'mas %s\n' "$*"
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/xcodebuild" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-license" && "${2:-}" == "check" ]]; then
    exit 1
fi

printf 'xcodebuild %s\n' "$*"
MOCK

    chmod +x \
        "${BIN_SANDBOX}/sudo" \
        "${BIN_SANDBOX}/softwareupdate" \
        "${BIN_SANDBOX}/brew" \
        "${BIN_SANDBOX}/mas" \
        "${BIN_SANDBOX}/xcodebuild"

    run env \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        OSTYPE="darwin24" \
        XCODE_APP_PATH="${TEST_TMPDIR}/Applications/Xcode.app" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-update"
    assert_success
    assert_output --partial "sudo softwareupdate --install --all"
    assert_output --partial "mas upgrade"
    assert_output --partial "sudo xcodebuild -license accept"
    assert_output --partial "brew update"
    assert_output --partial "brew upgrade"
    assert_output --partial "brew cleanup --prune=all"
    [[ ! -d "${TEST_TMPDIR}/Library/Caches/Homebrew" ]]
}

@test "os-update sources the repo common.sh through its stow symlink, not a planted one" {
    local home="${TEST_TMPDIR}/home"
    mkdir -p "${home}/.local/bin" "${TEST_TMPDIR}/scripts"
    ln -s "${PROJECT_ROOT}/stow/tools/.local/bin/os-update" "${home}/.local/bin/os-update"

    # Three levels above the link: the path the old lookup sourced.
    cat > "${TEST_TMPDIR}/scripts/common.sh" <<'PLANTED'
printf 'PLANTED common.sh\n'
touch "${TEST_TMPDIR}/planted-ran"
PLANTED

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*"
MOCK

    # The repo common.sh exports XDG_CONFIG_HOME; the inline fallback does not.
    cat > "${BIN_SANDBOX}/brew" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "--cache" ]] && exit 0
printf 'brew %s xdg=%s\n' "$*" "${XDG_CONFIG_HOME:-unset}"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/apt-get" "${BIN_SANDBOX}/brew"

    run env -u XDG_CONFIG_HOME HOME="${home}" DOTFILES_DIR="${TEST_TMPDIR}/no-dotfiles" \
        TEST_TMPDIR="${TEST_TMPDIR}" PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${home}/.local/bin/os-update"
    assert_success
    assert_output --partial "brew update xdg=${home}/.config"
    refute_output --partial "PLANTED"
    [[ ! -e "${TEST_TMPDIR}/planted-ran" ]]
}

@test "os-update only sources a fallback common.sh that others cannot write" {
    local copy_dir="${TEST_TMPDIR}/elsewhere/stow/tools/.local/bin"
    local dotfiles="${TEST_TMPDIR}/dots"
    mkdir -p "${copy_dir}" "${dotfiles}/scripts"
    cp "${PROJECT_ROOT}/stow/tools/.local/bin/os-update" "${copy_dir}/os-update"
    printf 'printf "FALLBACK SOURCED\\n"\n' > "${dotfiles}/scripts/common.sh"

    chmod 666 "${dotfiles}/scripts/common.sh"
    run env DOTFILES_DIR="${dotfiles}" "${copy_dir}/os-update" --help
    assert_success
    assert_output --partial "not sourcing ${dotfiles}/scripts/common.sh"
    refute_output --partial "FALLBACK SOURCED"

    chmod 644 "${dotfiles}/scripts/common.sh"
    run env DOTFILES_DIR="${dotfiles}" "${copy_dir}/os-update" --help
    assert_success
    assert_output --partial "FALLBACK SOURCED"
    refute_output --partial "not sourcing"
}

@test "os-update refuses to clear a Homebrew cache path that is not a Homebrew directory" {
    local home="${TEST_TMPDIR}/home"
    local reply=""
    mkdir -p "${home}" "${TEST_TMPDIR}/other-cache"

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/brew" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "--cache" ]]; then
    printf '%s\n' "${BREW_CACHE_REPLY}"
    exit 0
fi
printf 'brew %s\n' "$*"
MOCK

    # Record deletions instead of performing them, so a broken guard cannot
    # remove anything real.
    cat > "${BIN_SANDBOX}/rm" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMPDIR}/rm.log"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/apt-get" "${BIN_SANDBOX}/brew" "${BIN_SANDBOX}/rm"

    for reply in "" "/" "${home}" "${TEST_TMPDIR}/other-cache"; do
        run env HOME="${home}" TEST_TMPDIR="${TEST_TMPDIR}" BREW_CACHE_REPLY="${reply}" \
            PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
            "${PROJECT_ROOT}/stow/tools/.local/bin/os-update"
        assert_success
        assert_output --partial "not clearing unexpected Homebrew cache path"
        [[ ! -e "${TEST_TMPDIR}/rm.log" ]]
    done
}

@test "ph-update displays help" {
    run "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "ph-update"
    assert_output --partial "ph-update -r"
    assert_output --partial "Run os-update, refresh Pi-hole, update PADD, and optionally restart Linux"
}

@test "ph-update runs os-update before self-elevating through sudo" {
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update"
    assert_success
    assert_output --partial "sudo apt-get update"
    refute_output --partial "PATH="
    assert_output --partial "sudo PH_UPDATE_SKIP_OS_UPDATE=1 PH_UPDATE_PADD_BIN=${BIN_SANDBOX}/ph-padd ${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update"
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update" -r
    assert_success
    assert_output --partial "PH_UPDATE_SKIP_OS_UPDATE=1"
    assert_output --partial "ph-update -r"
}

@test "ph-update rejects -r on non-linux hosts" {
    run env OSTYPE="darwin23" \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update" -r
    assert_failure
    assert_output --partial "-r/--restart is only supported on Linux"
}

@test "ph-update restarts Linux after a successful run when -r is set" {
    local probe_script="${TEST_TMPDIR}/ph-update"
    ln -sf "${PROJECT_ROOT}/stow/tools/.local/bin/os-update" "${TEST_TMPDIR}/os-update"

    sed 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update" > "${probe_script}"
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
        "${probe_script}" -r
    assert_success
    assert_output --partial "Pi-hole update and gravity refresh completed"
    assert_output --partial "PADD update completed"
    assert_output --partial "shutdown -r now"
}

@test "ph-update fails before os-update when pihole is unavailable" {
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update"
    assert_failure
    assert_output --partial "pihole command is unavailable"
    [[ "${output}" != *"sudo apt-get update"* ]]
}

@test "ph-update as root searches only system directories, not the caller's PATH" {
    local probe_script="${TEST_TMPDIR}/ph-update"

    [[ ! -e /usr/local/bin/pihole && ! -e /usr/bin/pihole ]] || skip "pihole is installed on this host"

    # Take the root branch without being root; stay out of os-update and sudo.
    sed -e 's/^if (( EUID == 0 )); then$/if true; then/' \
        -e 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update" > "${probe_script}"
    chmod +x "${probe_script}"

    local cmd
    for cmd in pihole ph-padd shutdown gum; do
        printf '#!/usr/bin/env bash\ntouch "%s/user-path-used"\n' "${TEST_TMPDIR}" > "${BIN_SANDBOX}/${cmd}"
        chmod +x "${BIN_SANDBOX}/${cmd}"
    done

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" PH_UPDATE_SKIP_OS_UPDATE=1 \
        "${probe_script}"
    assert_failure
    assert_output --partial "pihole command is unavailable"
    [[ ! -e "${TEST_TMPDIR}/user-path-used" ]]
}

@test "ph-update runs ph-padd as the invoking user when elevated" {
    local probe_script="${TEST_TMPDIR}/ph-update"

    # Elevated branches without being root: skip the re-exec and treat
    # SUDO_USER as set by sudo.
    sed -e 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        -e 's/if \[\[ "${EUID}" -eq 0 \&\& -n "${SUDO_USER:-}" \]\]; then/if [[ -n "${SUDO_USER:-}" ]]; then/' \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-update" > "${probe_script}"
    chmod +x "${probe_script}"
    ln -sf "${PROJECT_ROOT}/stow/tools/.local/bin/os-update" "${TEST_TMPDIR}/os-update"

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    cat > "${BIN_SANDBOX}/pihole" <<'MOCK'
#!/usr/bin/env bash
printf 'pihole %s\n' "$*"
MOCK

    cat > "${TEST_TMPDIR}/padd-elsewhere" <<'MOCK'
#!/usr/bin/env bash
printf 'padd ran directly\n'
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/pihole" "${TEST_TMPDIR}/padd-elsewhere"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" PH_UPDATE_SKIP_OS_UPDATE=1 \
        SUDO_USER=pi PH_UPDATE_PADD_BIN="${TEST_TMPDIR}/padd-elsewhere" \
        "${probe_script}"
    assert_success
    assert_output --partial "sudo -u pi ${TEST_TMPDIR}/padd-elsewhere -u"
    refute_output --partial "padd ran directly"
    assert_output --partial "PADD update completed"
}

@test "ph-test displays help" {
    run "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test" --help
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test" 192.0.2.53
    assert_success
    refute_output --partial "PATH="
    assert_output --partial "sudo ${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test 192.0.2.53"
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test"
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test"
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

if [[ "$*" == *"google.com"* ]]; then
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test"
    assert_success
    assert_output --partial "AD flag not exposed on direct query to 127.0.0.1:5335"
    assert_output --partial "Re-test the direct resolver socket: dig @127.0.0.1 -p 5335 google.com +dnssec +adflag"

    run cat "${dig_log}"
    assert_success
    assert_output --partial "@127.0.0.1 -p 5335 google.com +dnssec +adflag"
}

@test "ph-test still prints summary when stats collection fails" {
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

if [[ "$*" == *"google.com +dnssec"* ]]; then
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test"
    assert_failure
    assert_output --partial "Summary"
    assert_output --partial "Could not retrieve stats"
    assert_output --partial "Found 1 failing check(s)."
}

@test "ph-test times out hung stats collection and still prints summary" {
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
        sleep 5
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

if [[ "$*" == *"google.com +dnssec"* ]]; then
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test"
    assert_failure
    assert_output --partial "Summary"
    assert_output --partial "Could not retrieve stats (timed out after 1s)"
    assert_output --partial "Found 1 failing check(s)."
}

@test "ph-test still prints summary when stats output omits some keys" {
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

if [[ "$*" == *"google.com +dnssec"* ]]; then
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test"
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
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-test" > "${probe_script}"
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

@test "ph-backup displays help" {
    run "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-backup" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "ph-backup [-o|--output DIR]"
    assert_output --partial "~/backups/ph-backup"
}

@test "ph-backup rejects unknown arguments before elevating" {
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-backup" --bogus
    assert_failure
    assert_output --partial "Unknown argument: --bogus"
    refute_output --partial "sudo "
}

@test "ph-backup refuses to run off Linux" {
    run env OSTYPE="darwin23" \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-backup"
    assert_failure
    assert_output --partial "only runs on the Linux host"
}

@test "ph-backup self-elevates through sudo and preserves the output directory" {
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-backup" -o /mnt/nas/pihole
    assert_success
    refute_output --partial "PATH="
    assert_output --partial "sudo ${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-backup -o /mnt/nas/pihole"
}

# ph-backup must run as root, so tests exercise a copy with the self-elevation
# block stripped out. Mocks stand in for Pi-hole, Unbound, Tailscale, and the
# GNU flags (stat -c, numfmt) that the Linux host provides but macOS does not.
setup_ph_backup_sandbox() {
    local teleporter_status="${1:-0}"

    cat > "${BIN_SANDBOX}/pihole-FTL" <<MOCK
#!/usr/bin/env bash
case "\${1}" in
    --teleporter)
        [[ "${teleporter_status}" -eq 0 ]] || exit 1
        # A real zip, so the restore map can enumerate its paths the way it
        # does against Pi-hole's own export.
        mkdir -p etc/pihole
        printf 'toml\n' > etc/pihole/pihole.toml
        printf 'hosts\n' > etc/hosts
        zip -qr "pi-hole_pi_teleporter_2026-01-01.zip" etc
        rm -rf etc
        printf 'pi-hole_pi_teleporter_2026-01-01.zip\n'
        ;;
    --config) printf '["127.0.0.1#5335"]\n' ;;
    sqlite3)
        case "\${3}" in
            *gravity*) printf '8843595\n' ;;
            *) printf '9\n' ;;
        esac
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/pihole" <<'MOCK'
#!/usr/bin/env bash
[[ "${1}" == "-v" ]] && printf 'Core version is v6.1.4\n'
MOCK

    # Peer "m" carries Mullvad's shared-exit-node tag and must be filtered out.
    cat > "${BIN_SANDBOX}/tailscale" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1}" == "status" && "${2}" == "--json" ]]; then
    printf '{"Version":"1.90.2","BackendState":"Running","MagicDNSSuffix":"tail1.ts.net",'
    printf '"CurrentTailnet":{"Name":"example.com"},'
    printf '"Self":{"HostName":"pi","TailscaleIPs":["100.64.0.5"]},'
    printf '"Peer":{"a":{"HostName":"mac","Online":true},"b":{"HostName":"nas","Online":false},'
    printf '"m":{"HostName":"mullvad-lax","Online":true,"Tags":["tag:mullvad-exit-node"]}}}\n'
fi
MOCK

    cat > "${BIN_SANDBOX}/unbound-checkconf" <<MOCK
#!/usr/bin/env bash
case "\${2}" in
    config-file) printf '${TEST_TMPDIR}/etc/unbound/unbound.conf\n' ;;
    interface) printf '127.0.0.1\n' ;;
    port) printf '5335\n' ;;
    auto-trust-anchor-file) printf '${TEST_TMPDIR}/var/lib/unbound/root.key\n' ;;
    *) exit 0 ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/sqlite3" <<'MOCK'
#!/usr/bin/env bash
case "${2}" in
    *gravity*) printf '128432\n' ;;
    *) printf '7\n' ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'pi\n'
MOCK

    cat > "${BIN_SANDBOX}/stat" <<'MOCK'
#!/usr/bin/env bash
[[ "${1}" == "-c" && "${2}" == "%s" ]] && exec /usr/bin/stat -f%z "${3}"
exec /usr/bin/stat "$@"
MOCK

    chmod +x "${BIN_SANDBOX}/pihole-FTL" "${BIN_SANDBOX}/pihole" "${BIN_SANDBOX}/tailscale" \
        "${BIN_SANDBOX}/unbound-checkconf" "${BIN_SANDBOX}/sqlite3" "${BIN_SANDBOX}/hostname" \
        "${BIN_SANDBOX}/stat"

    mkdir -p "${TEST_TMPDIR}/etc/unbound/unbound.conf.d" "${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/var/lib/unbound" "${TEST_TMPDIR}/out"
    printf 'server:\n  port: 5335\n' > "${TEST_TMPDIR}/etc/unbound/unbound.conf.d/pi-hole.conf"
    printf 'gravity\n' > "${TEST_TMPDIR}/etc/pihole/gravity.db"
    # The trust anchor lives outside the config directory, as on Debian.
    printf 'anchor\n' > "${TEST_TMPDIR}/var/lib/unbound/root.key"

    awk '
        /^# Self-elevate if not root/ { skip = 1 }
        skip && /^fi$/ { skip = 0; next }
        skip { next }
        { print }
    ' "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-backup" > "${TEST_TMPDIR}/ph-backup"

    chmod +x "${TEST_TMPDIR}/ph-backup"
}

run_ph_backup_probe() {
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/out"
}

@test "ph-backup archives the three backups plus a summary" {
    setup_ph_backup_sandbox

    run_ph_backup_probe
    assert_success
    assert_output --partial "Teleporter archive captured"
    assert_output --partial "Tailscale state captured"
    assert_output --partial "SUMMARY.md written"
    assert_output --partial "Failed: 0"

    local archive
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"
    [[ -n "${archive}" ]]

    run tar -tzf "${archive}"
    assert_success
    assert_output --partial "SUMMARY.md"
    assert_output --partial "pi-hole_pi_teleporter_2026-01-01.zip"
    assert_output --partial "unbound-"
    assert_output --partial "tailscale-status-"
}

@test "ph-backup summary describes all three sources" {
    setup_ph_backup_sandbox

    run_ph_backup_probe
    assert_success

    local archive
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"

    run tar -xzOf "${archive}" '*/SUMMARY.md'
    assert_success
    assert_output --partial "Core version is v6.1.4"
    assert_output --partial "Gravity domains: 128432"
    assert_output --partial '127.0.0.1#5335'
    assert_output --partial "Backend state: Running"
    assert_output --partial "Tailnet: example.com"
    assert_output --partial "Peers: 2 total, 1 online"
    assert_output --partial "Keep it private"
}

@test "ph-backup maps every archived path to a restore destination" {
    setup_ph_backup_sandbox

    run_ph_backup_probe
    assert_success

    local archive
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"

    run tar -xzOf "${archive}" '*/SUMMARY.md'
    assert_success
    assert_output --partial "Restore map"

    # Every path inside the Teleporter zip and the Unbound tarball is listed
    # with the absolute path it belongs at.
    assert_output --partial '| `etc/pihole/pihole.toml` | `/etc/pihole/pihole.toml` |'
    assert_output --partial '| `etc/hosts` | `/etc/hosts` |'

    # Unbound paths are stored relative to / so each maps to one destination.
    local rel="${TEST_TMPDIR#/}"
    assert_output --partial '| `'"${rel}"'/etc/unbound/unbound.conf.d/pi-hole.conf` | `'"${TEST_TMPDIR}"'/etc/unbound/unbound.conf.d/pi-hole.conf` |'
    assert_output --partial '| `'"${rel}"'/var/lib/unbound/root.key` | `'"${TEST_TMPDIR}"'/var/lib/unbound/root.key` |'

    # Artifacts that restore nowhere say so outright.
    assert_output --partial "Restores to: nothing"
}

@test "ph-backup contents table names a destination for every file" {
    setup_ph_backup_sandbox
    printf 'server:\n' > "${TEST_TMPDIR}/etc/unbound/unbound.conf"

    run_ph_backup_probe
    assert_success

    local archive
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"

    run tar -xzOf "${archive}" '*/SUMMARY.md'
    assert_success
    assert_output --partial "| File | Size | Restores to |"

    # Teleporter keeps /etc and /etc/pihole distinct; a top-level directory is
    # too broad to stand in for its children.
    assert_output --partial '| `/etc`, `/etc/pihole` |'

    # Unbound collapses its subdirectory into the config root.
    assert_output --partial '`'"${TEST_TMPDIR}"'/etc/unbound`, `'"${TEST_TMPDIR}"'/var/lib/unbound` |'

    # The two files that restore nowhere are listed, not omitted.
    assert_output --partial "| nothing — reference only |"
    assert_output --partial '| `SUMMARY.md` | — | nothing — this file |'

    # Checksums survive the move out of the contents table.
    assert_output --partial "## Checksums"
    assert_output --partial "sha256sum -c"
}

@test "ph-backup includes the DNSSEC trust anchor from outside the config dir" {
    setup_ph_backup_sandbox

    run_ph_backup_probe
    assert_success

    local archive inner
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"
    inner="${TEST_TMPDIR}/inner"
    mkdir -p "${inner}"
    tar -xzf "${archive}" -C "${inner}"

    run tar -tzf "$(find "${inner}" -name 'unbound-*.tar.gz' -print -quit)"
    assert_success
    assert_output --partial "${TEST_TMPDIR#/}/etc/unbound/unbound.conf.d/pi-hole.conf"
    assert_output --partial "${TEST_TMPDIR#/}/var/lib/unbound/root.key"
}

@test "ph-backup drops Mullvad exit nodes from the Tailscale state" {
    setup_ph_backup_sandbox

    run_ph_backup_probe
    assert_success

    local archive inner state
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"
    inner="${TEST_TMPDIR}/inner"
    mkdir -p "${inner}"
    tar -xzf "${archive}" -C "${inner}"
    state="$(find "${inner}" -name 'tailscale-status-*.json' -print -quit)"

    run jq -r '.Peer | keys | join(",")' "${state}"
    assert_success
    assert_output "a,b"

    run tar -xzOf "${archive}" '*/SUMMARY.md'
    assert_output --partial "Peers: 2 total"
    assert_output --partial "Filtered out: 1 shared Mullvad exit nodes"
}

@test "ph-backup copies the archive off-box when a destination is given" {
    setup_ph_backup_sandbox

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/out" --copy-to "${TEST_TMPDIR}/offbox"
    assert_success
    assert_output --partial "Archive copied to ${TEST_TMPDIR}/offbox"

    run find "${TEST_TMPDIR}/offbox" -name 'ph-backup-pi-*.tar.gz'
    assert_output --partial "ph-backup-pi-"
}

@test "ph-backup warns without failing when the off-box copy cannot be written" {
    setup_ph_backup_sandbox

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/out" \
        --copy-to "${TEST_TMPDIR}/etc/pihole/gravity.db/nope"
    assert_success
    assert_output --partial "Could not copy the archive"
    assert_output --partial "Warnings: 1"
}

@test "ph-backup reads gravity stats through pihole-FTL when sqlite3 cannot" {
    setup_ph_backup_sandbox

    # The Pi has no sqlite3 package at all; a stub that returns nothing stands
    # in for that, since the host running these tests has its own sqlite3.
    cat > "${BIN_SANDBOX}/sqlite3" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK

    chmod +x "${BIN_SANDBOX}/sqlite3"

    run_ph_backup_probe
    assert_success

    local archive
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"

    run tar -xzOf "${archive}" '*/SUMMARY.md'
    assert_success
    assert_output --partial "Gravity domains: 8843595"
    assert_output --partial "Enabled adlists: 9"
    refute_output --partial "Gravity statistics: unavailable"
}

@test "ph-backup warns but still archives when Tailscale and Unbound are missing" {
    setup_ph_backup_sandbox
    rm "${BIN_SANDBOX}/tailscale"
    rm -rf "${TEST_TMPDIR}/etc/unbound"

    run_ph_backup_probe
    assert_success
    assert_output --partial "Could not capture Tailscale state"
    assert_output --partial "Could not archive"
    assert_output --partial "Warnings: 2"

    local archive
    archive="$(find "${TEST_TMPDIR}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"
    [[ -n "${archive}" ]]
}

@test "ph-backup writes no archive when the Teleporter export fails" {
    setup_ph_backup_sandbox 1

    run_ph_backup_probe
    assert_failure
    assert_output --partial "Teleporter export failed"
    assert_output --partial "Run pihole-FTL --teleporter manually"

    run find "${TEST_TMPDIR}/out" -name '*.tar.gz'
    assert_output ""
}

@test "ph-backup as root searches only system directories, not the caller's PATH" {
    local probe_script="${TEST_TMPDIR}/ph-backup-root"
    local dir

    for dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
        [[ ! -e "${dir}/pihole-FTL" && ! -e "${dir}/pihole" ]] || skip "Pi-hole is installed on this host"
    done

    # Take the root branch without being root.
    sed 's/if \[\[ "${EUID}" -ne 0 \]\]; then/if false; then/' \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-backup" > "${probe_script}"
    chmod +x "${probe_script}"

    local cmd
    for cmd in pihole-FTL pihole hostname tar gum sudo; do
        printf '#!/usr/bin/env bash\ntouch "%s/user-path-used"\n' "${TEST_TMPDIR}" > "${BIN_SANDBOX}/${cmd}"
        chmod +x "${BIN_SANDBOX}/${cmd}"
    done
    mkdir -p "${TEST_TMPDIR}/out"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${probe_script}" -o "${TEST_TMPDIR}/out"
    assert_failure
    assert_output --partial "neither pihole-FTL nor pihole is on PATH"
    [[ ! -e "${TEST_TMPDIR}/user-path-used" ]]
}

# Pin the snapshot timestamp so tests can plant files at the archive name.
mock_ph_backup_date() {
    cat > "${BIN_SANDBOX}/date" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "+%Y%m%d-%H%M%S" ]] && { printf '20260101-000000\n'; exit 0; }
exec /bin/date "$@"
MOCK
    chmod +x "${BIN_SANDBOX}/date"
}

@test "ph-backup creates a missing output directory owner-only with a 0600 archive" {
    setup_ph_backup_sandbox

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/fresh/backups"
    assert_success

    run find "${TEST_TMPDIR}/fresh/backups" -maxdepth 0 -perm 0700
    assert_output "${TEST_TMPDIR}/fresh/backups"

    run find "${TEST_TMPDIR}/fresh/backups" -name 'ph-backup-pi-*.tar.gz' -perm 0600
    assert_output --partial "ph-backup-pi-"

    # The temporary file was renamed into place, not left behind.
    run find "${TEST_TMPDIR}/fresh/backups" -name '.tmp.*'
    assert_output ""
}

@test "ph-backup refuses a symlinked or shared-writable output directory" {
    setup_ph_backup_sandbox
    mkdir -p "${TEST_TMPDIR}/real-out"
    ln -s "${TEST_TMPDIR}/real-out" "${TEST_TMPDIR}/link-out"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/link-out"
    assert_failure
    assert_output --partial "Refusing ${TEST_TMPDIR}/link-out: it is a symlink"
    assert_output --partial "Could not write the backup archive"

    run find "${TEST_TMPDIR}/real-out" -type f
    assert_output ""

    chmod 777 "${TEST_TMPDIR}/out"
    run_ph_backup_probe
    assert_failure
    assert_output --partial "it is writable by group or others"

    run find "${TEST_TMPDIR}/out" -type f
    assert_output ""
}

@test "ph-backup never writes through a symlink planted at the archive name" {
    setup_ph_backup_sandbox
    mock_ph_backup_date
    printf 'victim\n' > "${TEST_TMPDIR}/victim"
    ln -s "${TEST_TMPDIR}/victim" "${TEST_TMPDIR}/out/ph-backup-pi-20260101-000000.tar.gz"

    run_ph_backup_probe
    assert_failure
    assert_output --partial "Refusing to replace existing"

    run cat "${TEST_TMPDIR}/victim"
    assert_output "victim"
    [[ -L "${TEST_TMPDIR}/out/ph-backup-pi-20260101-000000.tar.gz" ]]

    run find "${TEST_TMPDIR}/out" -name '.tmp.*'
    assert_output ""
}

@test "ph-backup off-box copy never writes through a planted symlink" {
    setup_ph_backup_sandbox
    mock_ph_backup_date
    mkdir -p "${TEST_TMPDIR}/offbox"
    printf 'victim\n' > "${TEST_TMPDIR}/victim"
    ln -s "${TEST_TMPDIR}/victim" "${TEST_TMPDIR}/offbox/ph-backup-pi-20260101-000000.tar.gz"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/out" --copy-to "${TEST_TMPDIR}/offbox"
    assert_success
    assert_output --partial "Could not copy the archive"

    run cat "${TEST_TMPDIR}/victim"
    assert_output "victim"

    run find "${TEST_TMPDIR}/offbox" -name '.tmp.*'
    assert_output ""
}

@test "ph-backup writes the archive and scp copy as the invoking user" {
    setup_ph_backup_sandbox
    mkdir -p "${TEST_TMPDIR}/remote"

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
[[ "${1:-}" == "-u" ]] && shift 2
exec "$@"
MOCK

    # Stand in for the remote end, and report what scp was allowed to read.
    cat > "${BIN_SANDBOX}/scp" <<'MOCK'
#!/usr/bin/env bash
src="${2}"
[[ -O "${src}" ]] && printf 'scp source owned by caller\n'
[[ -n "$(find "${src}" -maxdepth 0 -perm 0600)" ]] && printf 'scp source mode 0600\n'
cp "${src}" "${TEST_TMPDIR}/remote/"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/scp"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" TEST_TMPDIR="${TEST_TMPDIR}" \
        SUDO_USER="$(id -un)" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/out" --copy-to nas:/backups
    assert_success
    assert_output --partial "Archive copied to nas:/backups"
    # The archive lands through a shell run as the invoking user, never root.
    assert_output --partial "sudo -u $(id -un) sh -c"
    assert_output --regexp "sudo -u $(id -un) scp -q ${TEST_TMPDIR}/out/ph-backup-pi-[^ ]*\.tar\.gz nas:/backups"
    assert_output --partial "scp source owned by caller"
    assert_output --partial "scp source mode 0600"

    run find "${TEST_TMPDIR}/remote" -name 'ph-backup-pi-*.tar.gz'
    assert_output --partial "ph-backup-pi-"
}

@test "ts-test displays help" {
    run bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ts-test" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "ts-test run"
    assert_output --partial "ts-test exit-node"
}

@test "ts-test runs the full suite by default in an isolated mocked environment" {
    cat > "${BIN_SANDBOX}/tailscale" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    status)
        if [[ "${2:-}" == "--json" ]]; then
            printf '{"BackendState":"Running","Self":{"DNSName":"node.example.ts.net."}}\n'
        else
            printf '100.64.0.1 node linux active\n'
            printf '100.64.0.2 peer linux active\n'
        fi
        ;;
    debug)
        printf '{"CorpDNS":true}\n'
        ;;
    ip)
        printf '100.64.0.1\n'
        ;;
    ping)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/dig" <<'MOCK'
#!/usr/bin/env bash
printf '100.64.0.1\n'
MOCK

    cat > "${BIN_SANDBOX}/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "${BIN_SANDBOX}/tailscale" "${BIN_SANDBOX}/dig" "${BIN_SANDBOX}/systemctl"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        bash "${PROJECT_ROOT}/stow/server.linux/.local/bin/ts-test"
    assert_success
    assert_output --partial "Platform: Linux"
    assert_output --partial "Backend: Running"
    assert_output --partial "Summary"
    assert_output --partial "All checks passed."
}

@test "sshkey displays help" {
    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "sshkey profiles"
    assert_output --partial "sshkey create [name]"
}

@test "sshkey create writes a local key inside an isolated home" {
    cat > "${BIN_SANDBOX}/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'sandbox-host\n'
MOCK

    cat > "${BIN_SANDBOX}/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

file=""
comment=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            file="$2"
            shift 2
            ;;
        -C)
            comment="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf 'PRIVATE KEY\n' > "${file}"
printf 'ssh-ed25519 LOCALKEY %s\n' "${comment}" > "${file}.pub"
MOCK

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "${BIN_SANDBOX}/hostname" "${BIN_SANDBOX}/ssh-keygen" "${BIN_SANDBOX}/ssh-add"
    mkdir -p "${TEST_TMPDIR}/home"

    run env HOME="${TEST_TMPDIR}/home" USER="sandbox-user" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" create devkey
    assert_success
    assert_output --partial "Generated local key at ${TEST_TMPDIR}/home/.ssh/devkey"
    [[ -f "${TEST_TMPDIR}/home/.ssh/devkey" ]]
    [[ -f "${TEST_TMPDIR}/home/.ssh/devkey.pub" ]]
}

@test "sshkey create uses the selected profile key when no name is provided" {
    cat > "${BIN_SANDBOX}/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'sandbox-host\n'
MOCK

    cat > "${BIN_SANDBOX}/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

file=""
comment=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            file="$2"
            shift 2
            ;;
        -C)
            comment="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf 'PRIVATE KEY\n' > "${file}"
printf 'ssh-ed25519 LOCALKEY %s\n' "${comment}" > "${file}.pub"
MOCK

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "${BIN_SANDBOX}/hostname" "${BIN_SANDBOX}/ssh-keygen" "${BIN_SANDBOX}/ssh-add"
    mkdir -p "${TEST_TMPDIR}/home/.config/sshkey"
    cat > "${TEST_TMPDIR}/home/.config/sshkey/config.toml" <<'EOF'
default_profile = "work"

[profiles.work]
key_name = "id_work"
storage = "local"
EOF

    run env HOME="${TEST_TMPDIR}/home" XDG_CONFIG_HOME="${TEST_TMPDIR}/home/.config" USER="sandbox-user" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" create
    assert_success
    assert_output --partial "Generated local key at ${TEST_TMPDIR}/home/.ssh/id_work"
    [[ -f "${TEST_TMPDIR}/home/.ssh/id_work" ]]
    [[ -f "${TEST_TMPDIR}/home/.ssh/id_work.pub" ]]
}

@test "sshkey maps legacy home machine type to the personal profile" {
    cat > "${BIN_SANDBOX}/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'sandbox-host\n'
MOCK

    cat > "${BIN_SANDBOX}/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

file=""
comment=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            file="$2"
            shift 2
            ;;
        -C)
            comment="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf 'PRIVATE KEY\n' > "${file}"
printf 'ssh-ed25519 LOCALKEY %s\n' "${comment}" > "${file}.pub"
MOCK

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "${BIN_SANDBOX}/hostname" "${BIN_SANDBOX}/ssh-keygen" "${BIN_SANDBOX}/ssh-add"
    mkdir -p "${TEST_TMPDIR}/home/.config/sshkey"
    cat > "${TEST_TMPDIR}/home/.config/sshkey/config.toml" <<'EOF'
[profiles.personal]
key_name = "id_personal"
storage = "local"
EOF

    run env HOME="${TEST_TMPDIR}/home" XDG_CONFIG_HOME="${TEST_TMPDIR}/home/.config" USER="sandbox-user" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" create -m home
    assert_success
    assert_output --partial "Generated local key at ${TEST_TMPDIR}/home/.ssh/id_personal"
    [[ -f "${TEST_TMPDIR}/home/.ssh/id_personal" ]]
    [[ -f "${TEST_TMPDIR}/home/.ssh/id_personal.pub" ]]
}

@test "sshkey cleanup fixes perms and removes orphaned files inside an isolated home" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_test"
    printf 'ssh-ed25519 KEEP keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_test.pub"
    printf 'ssh-ed25519 ORPHAN orphan@test\n' > "${TEST_TMPDIR}/home/.ssh/id_orphan.pub"
    cat > "${TEST_TMPDIR}/home/.ssh/known_hosts" <<'EOF'
example.com ssh-ed25519 AAAATEST

example.com ssh-ed25519 AAAATEST
github.com ssh-ed25519 BADKEY
EOF
    chmod 755 "${TEST_TMPDIR}/home/.ssh"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/id_test"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/id_test.pub"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/known_hosts"

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -l)
        exit 0
        ;;
    -d)
        exit 0
        ;;
esac

exit 0
MOCK

    chmod +x "${BIN_SANDBOX}/ssh-add"

    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" cleanup -y
    assert_success
    assert_output --partial "Cleaned"
    [[ ! -e "${TEST_TMPDIR}/home/.ssh/id_orphan.pub" ]]
    run bash -c '
        stat_mode() {
            stat -f "%Lp" "$1" 2>/dev/null || stat -c "%a" "$1" 2>/dev/null
        }
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh"'")" == "700" ]]
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh/id_test"'")" == "600" ]]
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh/id_test.pub"'")" == "644" ]]
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh/known_hosts"'")" == "644" ]]
    '
    assert_success
    run bash -c 'grep -c "^example.com ssh-ed25519 AAAATEST$" "'"${TEST_TMPDIR}/home/.ssh/known_hosts"'" || true'
    assert_success
    assert_output "1"
    run bash -c 'grep -c "^github.com " "'"${TEST_TMPDIR}/home/.ssh/known_hosts"'" || true'
    assert_success
    assert_output "0"
}

@test "sshkey cleanup dry run previews changes without modifying files" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_test"
    printf 'ssh-ed25519 KEEP keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_test.pub"
    printf 'ssh-ed25519 ORPHAN orphan@test\n' > "${TEST_TMPDIR}/home/.ssh/id_orphan.pub"
    cat > "${TEST_TMPDIR}/home/.ssh/known_hosts" <<'EOF'
example.com ssh-ed25519 AAAATEST

example.com ssh-ed25519 AAAATEST
github.com ssh-ed25519 BADKEY
EOF
    chmod 755 "${TEST_TMPDIR}/home/.ssh"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/id_test"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/id_test.pub"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/known_hosts"

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -l)
        exit 0
        ;;
    -d)
        exit 0
        ;;
esac

exit 0
MOCK

    chmod +x "${BIN_SANDBOX}/ssh-add"

    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" cleanup --dry-run
    assert_success
    assert_output --partial "Would remove ${TEST_TMPDIR}/home/.ssh/id_orphan.pub"
    assert_output --partial "Would fix permissions on ${TEST_TMPDIR}/home/.ssh"
    assert_output --partial "Would groom ${TEST_TMPDIR}/home/.ssh/known_hosts"
    assert_output --partial "Dry run: would clean 4 item(s)."
    [[ -e "${TEST_TMPDIR}/home/.ssh/id_orphan.pub" ]]
    run bash -c '
        stat_mode() {
            stat -f "%Lp" "$1" 2>/dev/null || stat -c "%a" "$1" 2>/dev/null
        }
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh"'")" == "755" ]]
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh/id_test"'")" == "644" ]]
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh/id_test.pub"'")" == "600" ]]
        [[ "$(stat_mode "'"${TEST_TMPDIR}/home/.ssh/known_hosts"'")" == "600" ]]
    '
    assert_success
    run bash -c 'grep -c "^example.com ssh-ed25519 AAAATEST$" "'"${TEST_TMPDIR}/home/.ssh/known_hosts"'" || true'
    assert_success
    assert_output "2"
    run bash -c 'grep -c "^github.com " "'"${TEST_TMPDIR}/home/.ssh/known_hosts"'" || true'
    assert_success
    assert_output "1"
}

@test "sshkey doctor tolerates multiline stat output and reports correct permissions" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    printf 'ssh-ed25519 KEEP keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_rsa"
    printf 'ssh-rsa KEEP keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_rsa.pub"
    printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' > "${TEST_TMPDIR}/home/.ssh/known_hosts"
    chmod 700 "${TEST_TMPDIR}/home/.ssh"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/id_ed25519" "${TEST_TMPDIR}/home/.ssh/id_rsa"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub" "${TEST_TMPDIR}/home/.ssh/id_rsa.pub" "${TEST_TMPDIR}/home/.ssh/known_hosts"

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    -l)
        exit 1
        ;;
    -L)
        exit 0
        ;;
esac

exit 0
MOCK

    cat > "${BIN_SANDBOX}/ssh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${BIN_SANDBOX}/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then
    target="${3:-}"
    if [[ -d "${target}" ]]; then
        printf '  File: "%s"\n700\n' "${target}"
    elif [[ "${target}" == *.pub || "${target}" == *known_hosts ]]; then
        printf '  File: "%s"\n644\n' "${target}"
    else
        printf '  File: "%s"\n600\n' "${target}"
    fi
    exit 0
fi

exit 1
MOCK

    chmod +x "${BIN_SANDBOX}/ssh-add" "${BIN_SANDBOX}/ssh" "${BIN_SANDBOX}/stat"

    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" doctor
    assert_failure
    assert_output --partial "~/.ssh permissions OK"
    refute_output --partial "Bad private key permissions"
    refute_output --partial "Bad public key permissions"
}

@test "sshkey doctor skips GitHub account failures when gh is not installed" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    printf 'ssh-ed25519 MATCHED keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub"
    printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' > "${TEST_TMPDIR}/home/.ssh/known_hosts"
    chmod 700 "${TEST_TMPDIR}/home/.ssh"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub" "${TEST_TMPDIR}/home/.ssh/known_hosts"

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    -l)
        exit 0
        ;;
    -L)
        printf 'ssh-ed25519 MATCHED keep@test\n'
        exit 0
        ;;
esac

exit 0
MOCK

    cat > "${BIN_SANDBOX}/ssh" <<'MOCK'
#!/usr/bin/env bash
printf "Hi keep@test! You've successfully authenticated, but GitHub does not provide shell access.\n" >&2
exit 1
MOCK

    chmod +x "${BIN_SANDBOX}/ssh-add" "${BIN_SANDBOX}/ssh"

    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" doctor
    assert_success
    assert_output --partial "GitHub CLI not installed — skipping GitHub account checks"
    assert_output --partial "SSH auth to github.com works"
    refute_output --partial "GitHub CLI is not authenticated"
    refute_output --partial "GitHub does not have a matching key blob"
}

@test "sshkey doctor falls back to find when stat does not report octal perms" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    printf 'ssh-ed25519 MATCHED keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub"
    printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' > "${TEST_TMPDIR}/home/.ssh/known_hosts"
    chmod 700 "${TEST_TMPDIR}/home/.ssh"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub" "${TEST_TMPDIR}/home/.ssh/known_hosts"

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    -l)
        exit 1
        ;;
    -L)
        exit 0
        ;;
esac

exit 0
MOCK

    cat > "${BIN_SANDBOX}/ssh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${BIN_SANDBOX}/stat" <<'MOCK'
#!/usr/bin/env bash
printf 'unsupported\n'
exit 1
MOCK

    cat > "${BIN_SANDBOX}/find" <<'MOCK'
#!/usr/bin/env bash
target="${1:-}"
if [[ -d "${target}" ]]; then
    printf '700\n'
elif [[ "${target}" == *.pub || "${target}" == *known_hosts ]]; then
    printf '644\n'
else
    printf '600\n'
fi
MOCK

    chmod +x "${BIN_SANDBOX}/ssh-add" "${BIN_SANDBOX}/ssh" "${BIN_SANDBOX}/stat" "${BIN_SANDBOX}/find"

    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" doctor
    assert_failure
    assert_output --partial "~/.ssh permissions OK"
    refute_output --partial "Bad private key permissions"
    refute_output --partial "Bad public key permissions"
}

@test "sshkey doctor skips GitHub account checks when gh is installed but signed out" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    printf 'ssh-ed25519 MATCHED keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub"
    printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' > "${TEST_TMPDIR}/home/.ssh/known_hosts"
    chmod 700 "${TEST_TMPDIR}/home/.ssh"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub" "${TEST_TMPDIR}/home/.ssh/known_hosts"

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    -l)
        exit 0
        ;;
    -L)
        printf 'ssh-ed25519 MATCHED keep@test\n'
        exit 0
        ;;
esac

exit 0
MOCK

    cat > "${BIN_SANDBOX}/ssh" <<'MOCK'
#!/usr/bin/env bash
printf "Hi keep@test! You've successfully authenticated, but GitHub does not provide shell access.\n" >&2
exit 1
MOCK

    cat > "${BIN_SANDBOX}/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "auth status")
        exit 1
        ;;
esac

exit 0
MOCK

    chmod +x "${BIN_SANDBOX}/ssh-add" "${BIN_SANDBOX}/ssh" "${BIN_SANDBOX}/gh"

    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" doctor
    assert_success
    assert_output --partial "GitHub CLI is not authenticated — skipping GitHub account checks"
    assert_output --partial "SSH auth to github.com works"
    refute_output --partial "GitHub does not have a matching key blob"
}

@test "sshkey doctor falls back to ls permissions when stat and find fail" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE KEY\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519"
    printf 'ssh-ed25519 MATCHED keep@test\n' > "${TEST_TMPDIR}/home/.ssh/id_ed25519.pub"
    printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n' > "${TEST_TMPDIR}/home/.ssh/known_hosts"

    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    -l)
        exit 1
        ;;
    -L)
        exit 0
        ;;
esac

exit 0
MOCK

    cat > "${BIN_SANDBOX}/ssh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "${BIN_SANDBOX}/stat" <<'MOCK'
#!/usr/bin/env bash
printf 'unsupported\n'
exit 1
MOCK

    cat > "${BIN_SANDBOX}/find" <<'MOCK'
#!/usr/bin/env bash
printf 'unsupported\n'
exit 1
MOCK

    cat > "${BIN_SANDBOX}/ls" <<'MOCK'
#!/usr/bin/env bash
target="${2:-}"
if [[ -d "${target}" ]]; then
    printf 'drwx------ 2 user user 4096 Jan  1 00:00 %s\n' "${target}"
elif [[ "${target}" == *.pub || "${target}" == *known_hosts ]]; then
    printf -- '-rw-r--r-- 1 user user 42 Jan  1 00:00 %s\n' "${target}"
else
    printf -- '-rw------- 1 user user 42 Jan  1 00:00 %s\n' "${target}"
fi
MOCK

    chmod +x "${BIN_SANDBOX}/ssh-add" "${BIN_SANDBOX}/ssh" "${BIN_SANDBOX}/stat" "${BIN_SANDBOX}/find" "${BIN_SANDBOX}/ls"

    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" doctor
    assert_failure
    assert_output --partial "~/.ssh permissions OK"
    refute_output --partial "Bad private key permissions"
    refute_output --partial "Bad public key permissions"
}

# sshkey: a mock `op` that records each call and answers with fixed JSON.
sshkey_mock_op() {
    local python_path=""

    python_path="$(command -v python3 || true)"
    [[ -n "${python_path}" ]] || skip "python3 is required"
    ln -sf "${python_path}" "${BIN_SANDBOX}/python3"

    cat > "${BIN_SANDBOX}/op" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_TMPDIR}/op.log"
for arg in "$@"; do
    printf '[%s]' "${arg}" >> "${TEST_TMPDIR}/op.args"
done
printf '\n' >> "${TEST_TMPDIR}/op.args"
case "${1:-} ${2:-}" in
    "account list") exit 0 ;;
    "vault get") exit 0 ;;
    "item list") printf '[{"id":"item1","title":"work key"}]\n' ;;
    "item get") printf '{"fields":[{"id":"public_key","value":"ssh-ed25519 OPBLOB x"}]}\n' ;;
    "item create")
        printf '{"fields":[{"id":"public_key","value":"ssh-ed25519 OPBLOB x"},'
        printf '{"id":"private_key","value":"-----BEGIN OPENSSH PRIVATE KEY-----"}]}\n'
        ;;
    *) exit 1 ;;
esac
MOCK
    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMPDIR}/ssh-add.log"
exit 0
MOCK
    chmod +x "${BIN_SANDBOX}/op" "${BIN_SANDBOX}/ssh-add"
}

@test "sshkey rejects a config key_name that escapes ~/.ssh" {
    mkdir -p "${TEST_TMPDIR}/home/.config/sshkey"
    cat > "${TEST_TMPDIR}/home/.config/sshkey/config.toml" <<'EOF'
default_profile = "work"

[profiles.work]
key_name = "../escaped"
storage = "local"
EOF
    cat > "${BIN_SANDBOX}/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >> "${TEST_TMPDIR}/ssh-keygen.log"
MOCK
    chmod +x "${BIN_SANDBOX}/ssh-keygen"

    for command in "create -y" "delete -y" "gh -y" "doctor"; do
        # shellcheck disable=SC2086 # split the command and its flag
        run env HOME="${TEST_TMPDIR}/home" XDG_CONFIG_HOME="${TEST_TMPDIR}/home/.config" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
            "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" ${command}
        assert_failure
        assert_output --partial "Key name must not contain /"
    done
    [[ ! -e "${TEST_TMPDIR}/ssh-keygen.log" ]]
    [[ ! -e "${TEST_TMPDIR}/home/escaped" ]]
}

@test "sshkey rejects an unsafe SSHKEY_GITHUB_KEY_NAME" {
    run env HOME="${TEST_TMPDIR}/home" SSHKEY_GITHUB_KEY_NAME="../../outside" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" gh -p personal -y
    assert_failure
    assert_output --partial "Key name must not contain /"
}

@test "sshkey 1Password create keeps the private key out of ~/.ssh" {
    sshkey_mock_op
    mkdir -p "${TEST_TMPDIR}/home"

    run env HOME="${TEST_TMPDIR}/home" USER="sandbox-user" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" create opkey -1p -y
    assert_success
    assert_output --partial "saved public key to ${TEST_TMPDIR}/home/.ssh/opkey.pub"
    [[ ! -e "${TEST_TMPDIR}/home/.ssh/opkey" ]]
    run cat "${TEST_TMPDIR}/home/.ssh/opkey.pub"
    assert_output "ssh-ed25519 OPBLOB x"
    run grep -rF "PRIVATE KEY" "${TEST_TMPDIR}/home"
    assert_failure
}

@test "sshkey passes a quoted vault name to op as one argument" {
    sshkey_mock_op
    mkdir -p "${TEST_TMPDIR}/home"

    run env HOME="${TEST_TMPDIR}/home" SSHKEY_1PASSWORD_VAULT="Bob's '], 'x" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" list -1p
    assert_success
    assert_output --partial "work key"
    run grep -F "[item][get][item1][--vault][Bob's '], 'x][--format=json]" "${TEST_TMPDIR}/op.args"
    assert_success
}

@test "sshkey cleanup removes its known_hosts temp files when a step fails" {
    mkdir -p "${TEST_TMPDIR}/home/.ssh" "${TEST_TMPDIR}/tmp"
    chmod 700 "${TEST_TMPDIR}/home/.ssh"
    printf 'example.com ssh-ed25519 AAAA\nexample.com ssh-ed25519 AAAA\n' > "${TEST_TMPDIR}/home/.ssh/known_hosts"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/known_hosts"
    cat > "${BIN_SANDBOX}/ssh-add" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    cat > "${BIN_SANDBOX}/mv" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "${BIN_SANDBOX}/ssh-add" "${BIN_SANDBOX}/mv"

    run env HOME="${TEST_TMPDIR}/home" TMPDIR="${TEST_TMPDIR}/tmp" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" cleanup -y
    assert_failure
    run find "${TEST_TMPDIR}/tmp" -name 'sshkey-known-hosts*'
    assert_success
    assert_output ""
}

# ph-agent-setup: mock the identity and platform so each step runs in the sandbox.
agent_setup_sandbox() {
    local user="${1}"
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    cat > "${BIN_SANDBOX}/uname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_UNAME:-Linux}"
MOCK
    cat > "${BIN_SANDBOX}/id" <<MOCK
#!/usr/bin/env bash
[[ "\${1:-}" == "-un" ]] && { printf '%s\n' "${user}"; exit 0; }
exit 0
MOCK
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${TEST_TMPDIR}/calls"
MOCK
    cat > "${BIN_SANDBOX}/git" <<'MOCK'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${TEST_TMPDIR}/calls"
MOCK
    chmod +x "${BIN_SANDBOX}/uname" "${BIN_SANDBOX}/id" "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/git"
}

run_agent_setup() {
    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-agent-setup" "$@"
}

@test "ph-agent-setup displays help" {
    run "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-agent-setup" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "user|install|authorize|link|schedule|import|status"
}

@test "ph-agent-setup rejects unknown and missing commands" {
    agent_setup_sandbox pi
    run_agent_setup bogus
    assert_failure 2
    assert_output --partial "unknown command: bogus"
    run_agent_setup
    assert_failure 2
    assert [ ! -e "${TEST_TMPDIR}/calls" ]
}

@test "ph-agent-setup user refuses to run off Linux before sudo" {
    agent_setup_sandbox pi
    MOCK_UNAME=Darwin run_agent_setup user
    assert_failure
    assert_output --partial "runs only on the Linux Pi-hole box"
    assert [ ! -e "${TEST_TMPDIR}/calls" ]
}

@test "ph-agent-setup steps refuse the wrong user" {
    agent_setup_sandbox agent
    run_agent_setup user
    assert_failure
    assert_output --partial "run 'user' as the admin user"
    agent_setup_sandbox pi
    run_agent_setup import
    assert_failure
    assert_output --partial "run 'import' as agent"
}

# Runs authorize with the contents of file ${1} on stdin.
run_agent_authorize() {
    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/server.linux/.local/bin/ph-agent-setup" authorize < "${1}"
}

@test "ph-agent-setup authorize adds one fetch-only key from stdin without its comment" {
    agent_setup_sandbox pi
    ssh-keygen -q -t ed25519 -N "" -C "agent@pihole vault read-only" -f "${TEST_TMPDIR}/ro"
    local blob
    blob="$(cut -d' ' -f2 "${TEST_TMPDIR}/ro.pub")"
    printf 'ssh-ed25519 AAAApersonal bran\n' > "${TEST_TMPDIR}/home/.ssh/authorized_keys"
    run_agent_authorize "${TEST_TMPDIR}/ro.pub"
    assert_success
    run_agent_authorize "${TEST_TMPDIR}/ro.pub"
    assert_success
    assert_output --partial "already authorized"
    run grep -c "${blob}" "${TEST_TMPDIR}/home/.ssh/authorized_keys"
    assert_output "1"
    run grep -Fx "restrict,command=\"git upload-pack 'git/vault.git'\" ssh-ed25519 ${blob} agent-vault-ro" \
        "${TEST_TMPDIR}/home/.ssh/authorized_keys"
    assert_success
    run grep -c "uploadpack.allowReachableSHA1InWant true" "${TEST_TMPDIR}/calls"
    assert_output "2"
}

@test "ph-agent-setup authorize rejects input that is not a public key" {
    agent_setup_sandbox pi
    touch "${TEST_TMPDIR}/home/.ssh/authorized_keys"
    printf 'command=evil\n' > "${TEST_TMPDIR}/input"
    run_agent_authorize "${TEST_TMPDIR}/input"
    assert_failure
    assert_output --partial "not an ed25519 public key"
    refute_output --partial "evil"
    assert [ ! -s "${TEST_TMPDIR}/home/.ssh/authorized_keys" ]
}

@test "ph-agent-setup authorize rejects a second key line, other key types, and invalid keys" {
    agent_setup_sandbox pi
    ssh-keygen -q -t ed25519 -N "" -f "${TEST_TMPDIR}/ro"
    ssh-keygen -q -t ed25519 -N "" -f "${TEST_TMPDIR}/extra"
    ssh-keygen -q -t rsa -b 2048 -N "" -f "${TEST_TMPDIR}/rsa"
    printf 'ssh-ed25519 AAAApersonal bran\n' > "${TEST_TMPDIR}/home/.ssh/authorized_keys"
    cp "${TEST_TMPDIR}/home/.ssh/authorized_keys" "${TEST_TMPDIR}/before"
    local input
    # A valid key followed by a second, unrestricted one.
    cat "${TEST_TMPDIR}/ro.pub" "${TEST_TMPDIR}/extra.pub" > "${TEST_TMPDIR}/two-lines"
    # A carriage return between two keys, without a newline.
    printf '%s\r%s\n' "$(cat "${TEST_TMPDIR}/ro.pub")" "$(cat "${TEST_TMPDIR}/extra.pub")" > "${TEST_TMPDIR}/cr"
    # Right shape, but not a key ssh-keygen can read.
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest agent\n' > "${TEST_TMPDIR}/bogus"
    for input in two-lines cr rsa.pub bogus; do
        run_agent_authorize "${TEST_TMPDIR}/${input}"
        assert_failure
        assert_output --partial "not an ed25519 public key"
    done
    run cmp "${TEST_TMPDIR}/before" "${TEST_TMPDIR}/home/.ssh/authorized_keys"
    assert_success
    run grep -c "uploadpack" "${TEST_TMPDIR}/calls"
    assert_failure
}

@test "ph-agent-setup user gives agent root-owned keys and commands without option-bearing keys" {
    agent_setup_sandbox pi
    # Record each sudo call; mirror installed files under root/ and answer the sshd query.
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${TEST_TMPDIR}/calls"
if [[ "${1}" == "install" && " $* " != *" -d "* ]]; then
    dst="${*: -1}"
    mkdir -p "${TEST_TMPDIR}/root$(dirname "${dst}")"
    cp "${*: -2:1}" "${TEST_TMPDIR}/root${dst}"
elif [[ "${1}" == "sshd" && "${2}" == "-T" ]]; then
    printf 'authorizedkeysfile /etc/ssh/authorized_keys/%%u\n'
fi
MOCK
    cat > "${TEST_TMPDIR}/home/.ssh/authorized_keys" <<'KEYS'
ssh-ed25519 AAAApersonal bran@mac
restrict,command="git receive-pack 'git/vault.git'" ssh-ed25519 AAAApush vault-push
from="10.0.0.1" ssh-rsa AAAAfrom limited
ecdsa-sha2-nistp256 AAAAecdsa bran@phone
KEYS
    run_agent_setup user
    assert_success
    run cat "${TEST_TMPDIR}/root/etc/ssh/authorized_keys/agent"
    assert_output "$(printf 'ssh-ed25519 AAAApersonal bran@mac\necdsa-sha2-nistp256 AAAAecdsa bran@phone')"
    run grep -F "sudo install -m 644 -o root -g root /dev/stdin /etc/ssh/authorized_keys/agent" "${TEST_TMPDIR}/calls"
    assert_success
    run grep -F "AuthorizedKeysFile /etc/ssh/authorized_keys/%u" "${TEST_TMPDIR}/root/etc/ssh/sshd_config.d/ph-agent-setup.conf"
    assert_success
    run grep -F "sudo install -m 755 -o root -g root" "${TEST_TMPDIR}/calls"
    assert_output --partial "/usr/local/bin/ph-agent-setup"
    assert_output --partial "/usr/local/bin/vault-lint"
    assert_output --partial "/usr/local/bin/vault-mv"
    assert_output --partial "/usr/local/bin/vault-cp"
    run grep -c -- "-o agent" "${TEST_TMPDIR}/calls"
    assert_output "1"
    run cat "${TEST_TMPDIR}/root/usr/local/bin/vault-mv"
    assert_output --partial 'exec /usr/local/bin/ph-agent-setup mv "$@"'
    run cat "${TEST_TMPDIR}/root/usr/local/bin/vault-cp"
    assert_output --partial 'exec /usr/local/bin/ph-agent-setup cp "$@"'
}

@test "ph-agent-setup schedule keeps exactly one tagged cron entry" {
    agent_setup_sandbox agent
    cat > "${BIN_SANDBOX}/crontab" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-l" ]]; then cat "${TEST_TMPDIR}/crontab" 2>/dev/null; exit 0; fi
cat > "${TEST_TMPDIR}/crontab"
MOCK
    chmod +x "${BIN_SANDBOX}/crontab"
    printf '@reboot other-job\n' > "${TEST_TMPDIR}/crontab"
    run_agent_setup schedule
    assert_success
    run_agent_setup schedule
    assert_success
    run grep -c "# ph-agent-setup import" "${TEST_TMPDIR}/crontab"
    assert_output "1"
    run grep -c "^0 7 \* \* \* /usr/local/bin/ph-agent-setup import " "${TEST_TMPDIR}/crontab"
    assert_output "1"
    run grep -c "@reboot other-job" "${TEST_TMPDIR}/crontab"
    assert_output "1"
}

@test "ph-agent-setup import syncs and skips Claude when the inbox is empty" {
    agent_setup_sandbox agent
    mkdir -p "${TEST_TMPDIR}/home/blife/_inbox"
    touch "${TEST_TMPDIR}/home/blife/_inbox/.gitkeep" "${TEST_TMPDIR}/home/blife/_inbox/.DS_Store"
    local tool
    for tool in ob claude flock; do
        cat > "${BIN_SANDBOX}/${tool}" <<MOCK
#!/usr/bin/env bash
printf '${tool} %s\n' "\$*" >> "${TEST_TMPDIR}/calls"
MOCK
        chmod +x "${BIN_SANDBOX}/${tool}"
    done
    run_agent_setup import
    assert_success
    assert_output --partial "inbox empty"
    run grep -c "^ob sync --path ${TEST_TMPDIR}/home/blife" "${TEST_TMPDIR}/calls"
    assert_output "1"
    run grep -c "^claude" "${TEST_TMPDIR}/calls"
    assert_output "0"
}

@test "ph-agent-setup status counts hidden inbox files but not .gitkeep or .DS_Store" {
    agent_setup_sandbox agent
    mkdir -p "${TEST_TMPDIR}/home/blife/_inbox/sub"
    touch "${TEST_TMPDIR}/home/blife/_inbox/.gitkeep" \
        "${TEST_TMPDIR}/home/blife/_inbox/.DS_Store" \
        "${TEST_TMPDIR}/home/blife/_inbox/sub/.DS_Store" \
        "${TEST_TMPDIR}/home/blife/_inbox/.hidden-note" \
        "${TEST_TMPDIR}/home/blife/_inbox/sub/.gitkeep"
    run_agent_setup status
    assert_success
    assert_output --partial "inbox     2 file(s)"
}

@test "ph-agent-setup import gives Claude a vault-scoped allowlist without find, cp, or mv" {
    agent_setup_sandbox agent
    mkdir -p "${TEST_TMPDIR}/home/blife/_inbox" "${TEST_TMPDIR}/rootbin"
    touch "${TEST_TMPDIR}/home/blife/_inbox/scan.pdf"
    export PH_AGENT_BIN_DIR="${TEST_TMPDIR}/rootbin"
    local tool home="${TEST_TMPDIR}/home"
    for tool in vault-lint vault-mv vault-cp; do
        printf '#!/usr/bin/env bash\n' > "${PH_AGENT_BIN_DIR}/${tool}"
        chmod +x "${PH_AGENT_BIN_DIR}/${tool}"
    done
    for tool in ob flock; do
        cat > "${BIN_SANDBOX}/${tool}" <<MOCK
#!/usr/bin/env bash
printf '${tool} %s\n' "\$*" >> "${TEST_TMPDIR}/calls"
MOCK
        chmod +x "${BIN_SANDBOX}/${tool}"
    done
    # Keep a copy of the settings file Claude was started with.
    cat > "${BIN_SANDBOX}/claude" <<MOCK
#!/usr/bin/env bash
printf 'claude\n' >> "${TEST_TMPDIR}/calls"
while [[ \$# -gt 0 ]]; do
    [[ "\$1" == "--settings" ]] && cp "\$2" "${TEST_TMPDIR}/settings.json"
    shift
done
MOCK
    chmod +x "${BIN_SANDBOX}/claude"
    run_agent_setup import
    assert_success
    run grep -c "^claude" "${TEST_TMPDIR}/calls"
    assert_output "1"
    run jq -r '.permissions.allow[]' "${TEST_TMPDIR}/settings.json"
    assert_success
    assert_output --partial "Glob"
    refute_output --partial "find"
    refute_output --partial "Bash(cp"
    refute_output --partial "Bash(mv"
    assert_output --partial "Bash(vault-cp *)"
    run jq -r '.permissions.allow[] | select(test("^(Write|Edit)"))' "${TEST_TMPDIR}/settings.json"
    assert_output "$(printf 'Write(/%s/blife/**)\nEdit(/%s/blife/**)' "${home}" "${home}")"
    run jq -r '.permissions.deny[]' "${TEST_TMPDIR}/settings.json"
    assert_output --partial "Bash(curl *)"
    assert_output --partial "Write(/${home}/.local/**)"
    assert_output --partial "Edit(/${home}/.ssh/**)"
    assert_output --partial "Write(/${home}/.claude/**)"
    assert_output --partial "Edit(/${home}/.config/**)"
    assert_output --partial "Write(/${home}/.local/share/blife-tools/**)"
    assert_output --partial "Edit(**/.claude/**)"
}

@test "ph-agent-setup import refuses to start Claude without the root-owned helpers" {
    agent_setup_sandbox agent
    mkdir -p "${TEST_TMPDIR}/home/blife/_inbox" "${TEST_TMPDIR}/rootbin"
    touch "${TEST_TMPDIR}/home/blife/_inbox/scan.pdf"
    export PH_AGENT_BIN_DIR="${TEST_TMPDIR}/rootbin"
    local tool
    for tool in ob claude flock; do
        cat > "${BIN_SANDBOX}/${tool}" <<MOCK
#!/usr/bin/env bash
printf '${tool} %s\n' "\$*" >> "${TEST_TMPDIR}/calls"
MOCK
        chmod +x "${BIN_SANDBOX}/${tool}"
    done
    run_agent_setup import
    assert_failure
    assert_output --partial "run 'ph-agent-setup user' as pi"
    run grep -c "^claude" "${TEST_TMPDIR}/calls"
    assert_output "0"
}

@test "ph-agent-setup mv moves a file within the vault and nowhere else" {
    agent_setup_sandbox agent
    local vault="${TEST_TMPDIR}/home/blife"
    mkdir -p "${vault}/_inbox" "${vault}/_attachments/day" "${vault}/.claude" "${TEST_TMPDIR}/home/.local/bin"
    printf 'scan\n' > "${vault}/_inbox/scan.pdf"
    printf 'other\n' > "${vault}/_inbox/other.pdf"
    printf 'taken\n' > "${vault}/_attachments/day/taken.pdf"
    printf 'secret\n' > "${TEST_TMPDIR}/outside"
    ln -s "${TEST_TMPDIR}/outside" "${vault}/_inbox/link.pdf"

    run_agent_setup mv "${vault}/_inbox/other.pdf" "${TEST_TMPDIR}/home/.local/bin/vault-lint"
    assert_failure
    assert_output --partial "outside the vault"
    run_agent_setup mv "${vault}/_inbox/other.pdf" "${vault}/_attachments/../../.local/bin/x"
    assert_failure
    run_agent_setup mv "${vault}/_inbox/other.pdf" "${vault}/.claude/settings.json"
    assert_failure
    run_agent_setup mv "${vault}/_inbox/other.pdf" "${vault}/_attachments/day/taken.pdf"
    assert_failure
    assert_output --partial "destination exists"
    run_agent_setup mv "${vault}/_inbox/link.pdf" "${vault}/_attachments/day/"
    assert_failure
    assert_output --partial "not a regular file"
    run_agent_setup mv "${TEST_TMPDIR}/outside" "${vault}/_attachments/day/"
    assert_failure
    assert_output --partial "source is outside the vault"
    assert [ -f "${vault}/_inbox/other.pdf" ]
    assert [ ! -e "${TEST_TMPDIR}/home/.local/bin/vault-lint" ]
    assert [ ! -e "${TEST_TMPDIR}/home/.local/bin/x" ]
    run cat "${vault}/_attachments/day/taken.pdf"
    assert_output "taken"

    run_agent_setup mv "${vault}/_inbox/scan.pdf" "${vault}/_attachments/day/"
    assert_success
    assert [ ! -e "${vault}/_inbox/scan.pdf" ]
    run cat "${vault}/_attachments/day/scan.pdf"
    assert_output "scan"
}

@test "ph-agent-setup cp copies a file within the vault and nowhere else" {
    agent_setup_sandbox agent
    local vault="${TEST_TMPDIR}/home/blife"
    mkdir -p "${vault}/_attachments/_raw" "${vault}/_attachments/day" "${vault}/.claude" "${TEST_TMPDIR}/home/.local/bin"
    printf 'scan\n' > "${vault}/_attachments/_raw/scan.pdf"
    printf 'taken\n' > "${vault}/_attachments/day/taken.pdf"
    printf 'secret\n' > "${TEST_TMPDIR}/outside"
    ln -s "${TEST_TMPDIR}/outside" "${vault}/_attachments/_raw/link.pdf"

    run_agent_setup cp "${vault}/_attachments/_raw/scan.pdf" "${TEST_TMPDIR}/home/.local/bin/vault-lint"
    assert_failure
    assert_output --partial "outside the vault"
    run_agent_setup cp "${vault}/_attachments/_raw/scan.pdf" "${vault}/.claude/settings.json"
    assert_failure
    run_agent_setup cp "${vault}/_attachments/_raw/scan.pdf" "${vault}/_attachments/day/taken.pdf"
    assert_failure
    assert_output --partial "destination exists"
    run_agent_setup cp "${vault}/_attachments/_raw/link.pdf" "${vault}/_attachments/day/"
    assert_failure
    assert_output --partial "not a regular file"
    run_agent_setup cp "${TEST_TMPDIR}/outside" "${vault}/_attachments/day/"
    assert_failure
    assert_output --partial "source is outside the vault"
    assert [ ! -e "${TEST_TMPDIR}/home/.local/bin/vault-lint" ]
    run cat "${vault}/_attachments/day/taken.pdf"
    assert_output "taken"

    run_agent_setup cp "${vault}/_attachments/_raw/scan.pdf" "${vault}/_attachments/day/scan-2026.pdf"
    assert_success
    run cat "${vault}/_attachments/_raw/scan.pdf"
    assert_output "scan"
    run cat "${vault}/_attachments/day/scan-2026.pdf"
    assert_output "scan"
}
