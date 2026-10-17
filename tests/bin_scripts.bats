#!/usr/bin/env bats
# Tests for the stow/*/.local/bin scripts — isolated smoke and behavior coverage.

load test_helper

setup() {
    # Copies of the tools made by the tests find the shared helpers here.
    export DOTFILES_DIR="${PROJECT_ROOT}"
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

@test "os-doctor displays help" {
    run "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "os-doctor"
    assert_output --partial "package-manager updates"
}

@test "os-doctor runs linux apt and Homebrew updates" {
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
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    assert_output --partial "sudo apt-get update"
    assert_output --partial "sudo apt-get full-upgrade -y"
    assert_output --partial "sudo apt-get autoremove --purge -y"
    assert_output --partial "sudo apt-get autoclean -y"
    assert_output --partial "brew update"
    assert_line "brew upgrade --fetch-HEAD"
    assert_output --partial "brew cleanup --prune=all"
    [[ ! -d "${TEST_TMPDIR}/.cache/Homebrew" ]]
}

@test "os-doctor runs macOS system and Homebrew updates" {
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
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    assert_output --partial "sudo softwareupdate --install --all"
    assert_output --partial "mas upgrade"
    assert_output --partial "sudo xcodebuild -license accept"
    assert_output --partial "brew update"
    assert_line "brew upgrade --fetch-HEAD"
    assert_output --partial "brew cleanup --prune=all"
    [[ ! -d "${TEST_TMPDIR}/Library/Caches/Homebrew" ]]
}

@test "os-doctor removes orphaned Homebrew dependencies and installs missing ones" {
    mkdir -p "${TEST_TMPDIR}/.cache/Homebrew"
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    cat > "${BIN_SANDBOX}/brew" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    --cache) printf '%s\n' "${TEST_TMPDIR}/.cache/Homebrew" ;;
    missing) printf 'cairo: libpng pixman\nwebp: libtiff\n'; exit 1 ;;
    *) printf 'brew %s\n' "$*" ;;
esac
MOCK
    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/brew"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    assert_line "brew autoremove"
    assert_line "brew install libpng pixman libtiff"
}

@test "os-doctor prunes the uv and npm caches when they are installed" {
    mkdir -p "${TEST_TMPDIR}/.cache/Homebrew"
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    cat > "${BIN_SANDBOX}/brew" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "--cache" ]] && printf '%s\n' "${TEST_TMPDIR}/.cache/Homebrew"
exit 0
MOCK
    printf '#!/usr/bin/env bash\nprintf "uv %%s\\n" "$*"\n' > "${BIN_SANDBOX}/uv"
    printf '#!/usr/bin/env bash\nprintf "npm %%s\\n" "$*"\n' > "${BIN_SANDBOX}/npm"
    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/brew" "${BIN_SANDBOX}/uv" "${BIN_SANDBOX}/npm"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    assert_line "uv cache prune"
    assert_line "npm cache verify"

    printf '#!/usr/bin/env bash\nexit 2\n' > "${BIN_SANDBOX}/uv"
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    assert_output --partial "uv cache is in use; prune skipped"
    assert_line "npm cache verify"

    rm "${BIN_SANDBOX}/uv" "${BIN_SANDBOX}/npm"
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    assert_output --partial "nothing to prune"
}

@test "os-doctor updates zsh plugins through Homebrew's antidote" {
    local prefix="${TEST_TMPDIR}/brew-prefix"
    mkdir -p "${prefix}/opt/antidote/share/antidote" "${TEST_TMPDIR}/.cache/Homebrew"
    : > "${prefix}/opt/antidote/share/antidote/antidote.zsh"

    cat > "${BIN_SANDBOX}/brew" <<MOCK
#!/usr/bin/env bash
case "\${1:-}" in
    --cache) printf '%s\n' "${TEST_TMPDIR}/.cache/Homebrew" ;;
    --prefix) printf '%s\n' "${prefix}" ;;
    *) printf 'brew %s\n' "\$*" ;;
esac
MOCK

    cat > "${BIN_SANDBOX}/zsh" <<'MOCK'
#!/usr/bin/env bash
printf 'zsh ANTIDOTE_HOME=%s args=%s\n' "${ANTIDOTE_HOME}" "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/brew" "${BIN_SANDBOX}/zsh"

    run env -u ANTIDOTE_HOME PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        HOME="${TEST_TMPDIR}" XDG_CACHE_HOME="${TEST_TMPDIR}/.cache" APT_GET_BIN=no-apt-get \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    assert_line "zsh ANTIDOTE_HOME=${TEST_TMPDIR}/.cache/antidote args=-fc source \"\$1\" && antidote update zsh ${prefix}/opt/antidote/share/antidote/antidote.zsh"
    assert_output --partial "PASS  zsh plugin updates completed"
}

@test "os-doctor skips zsh plugins when antidote is not installed" {
    cat > "${BIN_SANDBOX}/zsh" <<'MOCK'
#!/usr/bin/env bash
printf 'zsh called\n'
MOCK
    chmod +x "${BIN_SANDBOX}/zsh"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        APT_GET_BIN=no-apt-get BREW_BIN=no-brew ANTIDOTE_ZSH="${TEST_TMPDIR}/missing/antidote.zsh" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
    assert_success
    refute_output --partial "zsh called"
    assert_output --partial "antidote not installed; skipping zsh plugin updates"
}

@test "os-doctor sources the repo common.sh through its stow symlink, not a planted one" {
    local home="${TEST_TMPDIR}/home"
    mkdir -p "${home}/.local/bin" "${TEST_TMPDIR}/scripts"
    ln -s "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor" "${home}/.local/bin/os-doctor"

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

    run env -u XDG_CONFIG_HOME -u DOTFILES_DIR HOME="${home}" \
        TEST_TMPDIR="${TEST_TMPDIR}" PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${home}/.local/bin/os-doctor"
    assert_success
    assert_output --partial "brew update xdg=${home}/.config"
    refute_output --partial "PLANTED"
    [[ ! -e "${TEST_TMPDIR}/planted-ran" ]]
}

@test "os-doctor refuses to clear a Homebrew cache path that is not a Homebrew directory" {
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
            "${PROJECT_ROOT}/stow/tools/.local/bin/os-doctor"
        assert_success
        assert_output --partial "not clearing unexpected Homebrew cache path"
        [[ ! -e "${TEST_TMPDIR}/rm.log" ]]
    done
}

setup_cf_cert_sandbox() {
    export ACME_HOME="${TEST_TMPDIR}/acme"
    mkdir -p "${ACME_HOME}"
    printf "SAVED_CF_Token='x'\n" > "${ACME_HOME}/account.conf"
    cat > "${ACME_HOME}/acme.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ACME_HOME}/calls.log"
[[ " $* " != *" --issue "* ]] || exit "${ACME_ISSUE_STATUS:-0}"
MOCK
    printf '#!/usr/bin/env bash\nexit 1\n' > "${BIN_SANDBOX}/crontab"
    chmod +x "${ACME_HOME}/acme.sh" "${BIN_SANDBOX}/crontab"
    CF_CERT="${PROJECT_ROOT}/stow/personal/.local/bin/cf-cert"
}

@test "cf-cert displays help" {
    run "${PROJECT_ROOT}/stow/personal/.local/bin/cf-cert" --help
    assert_success
    assert_output --partial "Usage: cf-cert [options] DOMAIN"
    assert_output --partial "--pihole"
}

@test "cf-cert requires one domain and rejects unknown options" {
    run "${PROJECT_ROOT}/stow/personal/.local/bin/cf-cert"
    assert_failure 2
    run "${PROJECT_ROOT}/stow/personal/.local/bin/cf-cert" a.test b.test
    assert_failure 2
    run "${PROJECT_ROOT}/stow/personal/.local/bin/cf-cert" --bogus a.test
    assert_failure 2
    run "${PROJECT_ROOT}/stow/personal/.local/bin/cf-cert" --reload
    assert_failure 2
}

@test "cf-cert issues without installing when no destination is given" {
    setup_cf_cert_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${CF_CERT}" a.test
    assert_success
    assert_output --partial "nothing to install"
    run grep -c -- "--issue --dns dns_cf -d a.test --keylength ec-256" "${ACME_HOME}/calls.log"
    assert_output "1"
    run grep -- "--install-cert" "${ACME_HOME}/calls.log"
    assert_failure
}

@test "cf-cert installs a combined pem and chains the reload command" {
    setup_cf_cert_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" ACME_ISSUE_STATUS=2 "${CF_CERT}" \
        --pem-file /srv/tls/a.test.pem --reload "systemctl reload nginx" a.test
    assert_success
    run grep -- "--install-cert" "${ACME_HOME}/calls.log"
    assert_output "--home ${ACME_HOME} --install-cert -d a.test --ecc --key-file /srv/tls/a.test.key --fullchain-file /srv/tls/a.test.fullchain --reloadcmd cat /srv/tls/a.test.key /srv/tls/a.test.fullchain > /srv/tls/a.test.pem && chmod 600 /srv/tls/a.test.pem /srv/tls/a.test.key && systemctl reload nginx"
}

@test "cf-cert stops on a failed issue before installing" {
    setup_cf_cert_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" ACME_ISSUE_STATUS=1 "${CF_CERT}" --key-file /srv/k a.test
    assert_failure
    run grep -- "--install-cert" "${ACME_HOME}/calls.log"
    assert_failure
}

@test "cf-cert without a saved or given token fails on closed stdin before issuing" {
    setup_cf_cert_sandbox
    rm "${ACME_HOME}/account.conf"
    run env -u CF_Token PATH="${BIN_SANDBOX}:${PATH}" "${CF_CERT}" a.test < /dev/null
    assert_failure 1
    assert_output --partial "no Cloudflare API token given"
    [[ ! -e "${ACME_HOME}/calls.log" ]]
}

@test "cf-cert --pihole refuses to run without root" {
    if (( EUID == 0 )); then
        skip "running as root"
    fi
    setup_cf_cert_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${CF_CERT}" --pihole a.test
    assert_failure 1
    assert_output --partial "--pihole needs root"
    [[ ! -e "${ACME_HOME}/calls.log" ]]
}

@test "cf-cert quotes hostile paths in the reload command acme.sh runs later" {
    setup_cf_cert_sandbox
    # Keep the reload command as one argument, as acme.sh saves it for its cron.
    cat > "${ACME_HOME}/acme.sh" <<'MOCK'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    [[ "$1" != --reloadcmd ]] || printf '%s' "$2" > "${ACME_HOME}/reloadcmd"
    shift
done
MOCK
    local dir="${TEST_TMPDIR}/tls dir;touch PWNED;\$(touch PWNED2)"
    mkdir -p "${dir}"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${CF_CERT}" --pem-file "${dir}/a.test.pem" a.test
    assert_success

    printf 'KEY\n' > "${dir}/a.test.key"
    printf 'CHAIN\n' > "${dir}/a.test.fullchain"
    run bash -c "cd '${TEST_TMPDIR}' && $(cat "${ACME_HOME}/reloadcmd")"
    assert_success
    run cat "${dir}/a.test.pem"
    assert_output "$(printf 'KEY\nCHAIN')"
    run ls -l "${dir}/a.test.pem"
    assert_output --regexp '^-rw-------'
    [ ! -e "${TEST_TMPDIR}/PWNED" ] && [ ! -e "${TEST_TMPDIR}/PWNED2" ]
}

@test "cf-cert --pihole as root points Pi-hole at the pem and restarts it on renewal" {
    setup_cf_cert_sandbox
    sed 's/(( EUID == 0 )) || die "--pihole needs root/true || die "--pihole needs root/' "${CF_CERT}" > "${TEST_TMPDIR}/cf-cert"
    chmod +x "${TEST_TMPDIR}/cf-cert"

    # Without pihole-FTL it stops before acme.sh runs.
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" "${TEST_TMPDIR}/cf-cert" --pihole a.test
    assert_failure 1
    assert_output --partial "pihole-FTL not found"
    [ ! -e "${ACME_HOME}/calls.log" ]

    printf '#!/usr/bin/env bash\nprintf "pihole-FTL %%s\\n" "$*" >> "%s/ftl.log"\n' "${TEST_TMPDIR}" > "${BIN_SANDBOX}/pihole-FTL"
    chmod +x "${BIN_SANDBOX}/pihole-FTL"
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" "${TEST_TMPDIR}/cf-cert" --pihole a.test
    assert_success
    run cat "${TEST_TMPDIR}/ftl.log"
    assert_output "pihole-FTL --config webserver.domain a.test
pihole-FTL --config webserver.tls.cert /etc/pihole/a.test.pem"
    run grep -- "--install-cert" "${ACME_HOME}/calls.log"
    assert_output "--home ${ACME_HOME} --install-cert -d a.test --ecc --key-file /etc/pihole/a.test.key --fullchain-file /etc/pihole/a.test.fullchain --reloadcmd cat /etc/pihole/a.test.key /etc/pihole/a.test.fullchain > /etc/pihole/a.test.pem && chmod 600 /etc/pihole/a.test.pem /etc/pihole/a.test.key && chown pihole:pihole /etc/pihole/a.test.pem /etc/pihole/a.test.key && systemctl restart pihole-FTL"
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
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
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
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
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
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-test"
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

@test "ph-backup displays help" {
    run "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup" --help
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
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup" --bogus
    assert_failure
    assert_output --partial "Unknown argument: --bogus"
    refute_output --partial "sudo "
}

@test "ph-backup refuses to run off Linux" {
    run env OSTYPE="darwin23" \
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup"
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
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup" -o /mnt/nas/pihole
    assert_success
    refute_output --partial "PATH="
    assert_output --partial "sudo ${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup -o /mnt/nas/pihole"
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
    ' "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup" > "${TEST_TMPDIR}/ph-backup"

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
        "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup" > "${probe_script}"
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
    run bash "${PROJECT_ROOT}/stow/personal/.local/bin/ts-test" --help
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
        bash "${PROJECT_ROOT}/stow/personal/.local/bin/ts-test"
    assert_success
    assert_output --partial "Platform: Linux"
    assert_output --partial "Backend: Running"
    assert_output --partial "Summary"
    assert_output --partial "All checks passed."
}

@test "ts-test exit-node resolves the exit node from pretty-printed status" {
    cat > "${BIN_SANDBOX}/tailscale" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    status)
        if [[ "${2:-}" == "--json" ]]; then
            cat <<'JSON'
{
  "BackendState": "Running",
  "ExitNodeStatus": {
    "ID": "nExit123",
    "Online": true,
    "TailscaleIPs": [
      "100.64.0.9/32",
      "fd7a:115c:a1e0::9/128"
    ]
  }
}
JSON
        else
            printf '100.64.0.9 exitbox linux active; exit node; direct\n'
            printf '# To see the full list of exit nodes, run `tailscale exit-node list`\n'
        fi
        ;;
    debug) printf '{"ExitNodeID": "nExit123"}\n' ;;
    ping) printf '%s\n' "$*" >> "${TEST_TMPDIR}/pings" ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${BIN_SANDBOX}/tailscale"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" TEST_TMPDIR="${TEST_TMPDIR}" \
        bash "${PROJECT_ROOT}/stow/personal/.local/bin/ts-test" exit-node
    assert_success
    assert_output --partial "Using exit node exitbox"
    assert_output --partial "Exit node is reachable at 100.64.0.9"
    refute_output --partial "Could not resolve"
    refute_output --regexp "^ *To *$"
    run cat "${TEST_TMPDIR}/pings"
    assert_output "ping --timeout=3s 100.64.0.9"
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

# Plants KEY and KEY.pub in the sandbox home's ~/.ssh for the sshkey tests.
sshkey_plant_key() {
    mkdir -p "${TEST_TMPDIR}/home/.ssh"
    printf 'PRIVATE %s\n' "$1" > "${TEST_TMPDIR}/home/.ssh/$1"
    printf 'ssh-ed25519 AAAA%s %s\n' "$1" "$1" > "${TEST_TMPDIR}/home/.ssh/$1.pub"
    chmod 600 "${TEST_TMPDIR}/home/.ssh/$1"
}

run_sshkey() {
    printf '#!/usr/bin/env bash\nprintf "ssh-add %%s\\n" "$*" >> "%s/ssh-add.log"\n[[ "$1" != -l ]] || exit 1\n' "${TEST_TMPDIR}" > "${BIN_SANDBOX}/ssh-add"
    printf '#!/usr/bin/env bash\nprintf "sandbox-host\\n"\n' > "${BIN_SANDBOX}/hostname"
    chmod +x "${BIN_SANDBOX}/ssh-add" "${BIN_SANDBOX}/hostname"
    run env HOME="${TEST_TMPDIR}/home" USER="sandbox-user" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/stow/tools/.local/bin/sshkey" "$@"
}

@test "sshkey create and delete refuse --dry-run, which would skip the confirmation" {
    sshkey_plant_key devkey
    run_sshkey delete devkey --dry-run < /dev/null
    assert_failure 1
    assert_output --partial "--dry-run is only used with cleanup"
    run_sshkey create devkey -n < /dev/null
    assert_failure 1
    assert_output --partial "--dry-run is only used with cleanup"
    run cat "${TEST_TMPDIR}/home/.ssh/devkey"
    assert_output "PRIVATE devkey"
    [ -f "${TEST_TMPDIR}/home/.ssh/devkey.pub" ]
}

@test "sshkey delete removes a key and its agent entry only once confirmed" {
    sshkey_plant_key devkey
    sshkey_plant_key other

    run_sshkey delete devkey <<< "n"
    assert_failure 1
    assert_output --partial "Aborted"
    [ -f "${TEST_TMPDIR}/home/.ssh/devkey" ] && [ -f "${TEST_TMPDIR}/home/.ssh/devkey.pub" ]

    run_sshkey delete devkey -y < /dev/null
    assert_success
    assert_output --partial "Removed local key: devkey"
    [ ! -e "${TEST_TMPDIR}/home/.ssh/devkey" ] && [ ! -e "${TEST_TMPDIR}/home/.ssh/devkey.pub" ]
    [ -f "${TEST_TMPDIR}/home/.ssh/other" ] && [ -f "${TEST_TMPDIR}/home/.ssh/other.pub" ]
    run grep -x "ssh-add -d ${TEST_TMPDIR}/home/.ssh/devkey" "${TEST_TMPDIR}/ssh-add.log"
    assert_success

    run_sshkey delete devkey -y < /dev/null
    assert_failure 1
    assert_output --partial "No key files found for 'devkey'"
}

@test "sshkey never deletes or recreates the protected id_rsa, unless unprotected" {
    sshkey_plant_key id_rsa
    run_sshkey delete id_rsa -y < /dev/null
    assert_failure 1
    assert_output --partial "Refusing to modify protected key 'id_rsa'"
    run_sshkey create id_rsa -y < /dev/null
    assert_failure 1
    assert_output --partial "Refusing to modify protected key 'id_rsa'"
    run cat "${TEST_TMPDIR}/home/.ssh/id_rsa"
    assert_output "PRIVATE id_rsa"
    [ ! -e "${TEST_TMPDIR}/ssh-add.log" ] || ! grep -q -- "-d" "${TEST_TMPDIR}/ssh-add.log"

    SSHKEY_PROTECTED_LOCAL_KEY_NAME='' run_sshkey delete id_rsa -y < /dev/null
    assert_success
    [ ! -e "${TEST_TMPDIR}/home/.ssh/id_rsa" ]
}

@test "sshkey cleanup removes an orphaned private key but leaves the protected one as it is" {
    sshkey_plant_key id_rsa
    sshkey_plant_key id_old
    rm "${TEST_TMPDIR}/home/.ssh/id_rsa.pub" "${TEST_TMPDIR}/home/.ssh/id_old.pub"
    chmod 644 "${TEST_TMPDIR}/home/.ssh/id_rsa" "${TEST_TMPDIR}/home/.ssh/id_old"
    chmod 700 "${TEST_TMPDIR}/home/.ssh"

    run_sshkey cleanup -y < /dev/null
    assert_success
    assert_output --partial "Removed ${TEST_TMPDIR}/home/.ssh/id_old"
    [ ! -e "${TEST_TMPDIR}/home/.ssh/id_old" ]
    run grep -x "ssh-add -d ${TEST_TMPDIR}/home/.ssh/id_old" "${TEST_TMPDIR}/ssh-add.log"
    assert_success
    run cat "${TEST_TMPDIR}/home/.ssh/id_rsa"
    assert_output "PRIVATE id_rsa"
    run ls -l "${TEST_TMPDIR}/home/.ssh/id_rsa"
    assert_output --regexp '^-rw-r--r--'
}

# Copies a df- wrapper into a fake repo whose scripts/<name> prints its
# arguments, and links it from a bin directory the way stow would.
fake_df_repo() {
    local wrapper="$1" script="$2"
    FAKE_REPO="${TEST_TMPDIR}/fake repo"
    mkdir -p "${FAKE_REPO}/stow/tools/.local/bin" "${FAKE_REPO}/scripts" "${TEST_TMPDIR}/home/.local/bin"
    cp "${PROJECT_ROOT}/stow/tools/.local/bin/${wrapper}" "${FAKE_REPO}/stow/tools/.local/bin/"
    printf '#!/usr/bin/env bash\nprintf "%%s|" "${BASH_SOURCE[0]}" "$@"\n' > "${FAKE_REPO}/scripts/${script}"
    ln -s "../../../fake repo/stow/tools/.local/bin/${wrapper}" "${TEST_TMPDIR}/home/.local/bin/${wrapper}"
}

@test "df-link runs its repo's link.sh through the stow link with every argument" {
    fake_df_repo df-link link.sh
    run "${TEST_TMPDIR}/home/.local/bin/df-link" add --layer tools "a file"
    assert_success
    assert_output --partial "/fake repo/scripts/link.sh|add|--layer|tools|a file|"
}

@test "df-rm runs its repo's link.sh rm with every argument" {
    fake_df_repo df-rm link.sh
    run "${TEST_TMPDIR}/home/.local/bin/df-rm" --delete "a file"
    assert_success
    assert_output --partial "/fake repo/scripts/link.sh|rm|--delete|a file|"
}

@test "df-mv runs its repo's link.sh mv with every argument" {
    fake_df_repo df-mv link.sh
    run "${TEST_TMPDIR}/home/.local/bin/df-mv" --layer tools "a file"
    assert_success
    assert_output --partial "/fake repo/scripts/link.sh|mv|--layer|tools|a file|"
}

@test "df-doctor runs its repo's doctor.sh with every argument" {
    fake_df_repo df-doctor doctor.sh
    run "${TEST_TMPDIR}/home/.local/bin/df-doctor"
    assert_success
    assert_output --regexp "/fake repo/scripts/doctor\.sh\|$"

    run "${TEST_TMPDIR}/home/.local/bin/df-doctor" --fix --all
    assert_success
    assert_output --partial "doctor.sh|--fix|--all|"
}

# Sets up a fake remote machine for df-deploy: an origin repo with a link.sh that logs its
# calls, the remote home's clone of it, and a stub ssh that records its arguments and runs the
# remote command locally as that home.
df_deploy_sandbox() {
    local g=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main)
    DF_ORIGIN="${TEST_TMPDIR}/origin"
    DF_REMOTE_HOME="${TEST_TMPDIR}/remote-home"
    mkdir -p "${DF_ORIGIN}/scripts" "${DF_REMOTE_HOME}"
    printf '#!/usr/bin/env bash\necho "link.sh ran" >> "%s/calls"\n' "${TEST_TMPDIR}" > "${DF_ORIGIN}/scripts/link.sh"
    chmod +x "${DF_ORIGIN}/scripts/link.sh"
    "${g[@]}" init --quiet "${DF_ORIGIN}"
    "${g[@]}" -C "${DF_ORIGIN}" add . && "${g[@]}" -C "${DF_ORIGIN}" commit --quiet -m one
    "${g[@]}" clone --quiet "${DF_ORIGIN}" "${DF_REMOTE_HOME}/.dotfiles"
    cat > "${BIN_SANDBOX}/ssh" <<MOCK
#!/usr/bin/env bash
printf 'ssh %s %s\n' "\$1" "\$2" >> "${TEST_TMPDIR}/calls"
HOME="${DF_REMOTE_HOME}" bash -c "\$3"
MOCK
    chmod +x "${BIN_SANDBOX}/ssh"
    # Outside any git checkout, so the unpushed-commit check stays quiet.
    mkdir -p "${TEST_TMPDIR}/tools"
    cp "${PROJECT_ROOT}/stow/personal/.local/bin/df-deploy" "${TEST_TMPDIR}/tools/"
    DF_DEPLOY="${TEST_TMPDIR}/tools/df-deploy"
}

run_df_deploy() {
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" DF_DEPLOY_HOSTS="${DF_DEPLOY_HOSTS:-}" "${DF_DEPLOY}" "$@"
}

@test "df-deploy pulls and relinks" {
    df_deploy_sandbox
    local g=(git -c user.name=t -c user.email=t@example.com)
    printf 'two\n' > "${DF_ORIGIN}/two"
    "${g[@]}" -C "${DF_ORIGIN}" add . && "${g[@]}" -C "${DF_ORIGIN}" commit --quiet -m two

    run_df_deploy box
    assert_success
    run cat "${TEST_TMPDIR}/calls"
    assert_output "$(printf 'ssh -t box\nlink.sh ran')"
    run git -C "${DF_REMOTE_HOME}/.dotfiles" log -1 --format=%s
    assert_output "two"
}

@test "df-deploy updates every named host" {
    df_deploy_sandbox
    DF_DEPLOY_HOSTS="one two" run_df_deploy
    assert_success
    run grep -c "^ssh -t " "${TEST_TMPDIR}/calls"
    assert_output "2"
    run grep -c "link.sh ran" "${TEST_TMPDIR}/calls"
    assert_output "2"
}

@test "df-deploy stops a host whose pull is not a fast-forward, and says which failed" {
    df_deploy_sandbox
    local g=(git -c user.name=t -c user.email=t@example.com)
    printf 'local\n' > "${DF_REMOTE_HOME}/.dotfiles/local-change"
    "${g[@]}" -C "${DF_REMOTE_HOME}/.dotfiles" add . && "${g[@]}" -C "${DF_REMOTE_HOME}/.dotfiles" commit --quiet -m diverge
    printf 'origin\n' > "${DF_ORIGIN}/origin-change"
    "${g[@]}" -C "${DF_ORIGIN}" add . && "${g[@]}" -C "${DF_ORIGIN}" commit --quiet -m other

    run_df_deploy box
    assert_failure
    assert_output --partial "df-deploy: box failed"
    run grep -c "link.sh ran" "${TEST_TMPDIR}/calls"
    assert_output "0"
}

@test "df-deploy carries on past a failed host and still fails" {
    df_deploy_sandbox
    cat > "${BIN_SANDBOX}/ssh" <<MOCK
#!/usr/bin/env bash
printf 'ssh %s %s\n' "\$1" "\$2" >> "${TEST_TMPDIR}/calls"
[[ "\$2" != down ]] || exit 255
HOME="${DF_REMOTE_HOME}" bash -c "\$3"
MOCK
    DF_DEPLOY_HOSTS="one down two" run_df_deploy
    assert_failure
    assert_output --partial "df-deploy: down failed"
    refute_output --partial "df-deploy: one failed"
    refute_output --partial "df-deploy: two failed"
    run cat "${TEST_TMPDIR}/calls"
    assert_output "$(printf 'ssh -t one\nlink.sh ran\nssh -t down\nssh -t two\nlink.sh ran')"
}

@test "df-deploy needs a host, prints commands on a dry run, and warns about unpushed commits" {
    df_deploy_sandbox
    run_df_deploy
    assert_failure
    assert_output --partial "name a host, or set DF_DEPLOY_HOSTS"

    run_df_deploy --dry-run box
    assert_success
    assert_output --partial "ssh -t box bash -c "
    [ ! -e "${TEST_TMPDIR}/calls" ]

    # A checkout one commit ahead of its upstream.
    local g=(git -c user.name=t -c user.email=t@example.com) mac="${TEST_TMPDIR}/mac"
    "${g[@]}" clone --quiet "${DF_ORIGIN}" "${mac}"
    "${g[@]}" -C "${mac}" commit --quiet --allow-empty -m unpushed
    mkdir -p "${mac}/stow/personal/.local/bin"
    cp "${PROJECT_ROOT}/stow/personal/.local/bin/df-deploy" "${mac}/stow/personal/.local/bin/"
    DF_DEPLOY="${mac}/stow/personal/.local/bin/df-deploy" run_df_deploy box
    assert_success
    assert_output --partial "1 commit(s) here are not pushed"
}

@test "df- wrappers fail clearly outside a dotfiles repo" {
    mkdir -p "${TEST_TMPDIR}/loose"
    cp "${PROJECT_ROOT}/stow/tools/.local/bin/df-link" "${TEST_TMPDIR}/loose/"
    run "${TEST_TMPDIR}/loose/df-link" status
    assert_failure
    assert_output --partial "cannot find scripts/link.sh"
}

# st only imports iterm2 when it talks to iTerm2, so --list and
# --dry-run run under plain python3 without its uv dependencies.
_st() {
    python3 "${PROJECT_ROOT}/stow/desktop.darwin/.local/bin/st" "$@"
}

_write_teams() {
    export CLAUDE_TEAM_CONFIG="${TEST_TMPDIR}/teams.toml"
    cat > "${CLAUDE_TEAM_CONFIG}" <<'TOML'
[crew]
dir = "/work/crew"
args = ["--model", "opus"]

[crew.lead]
prompt = "/lead plan it"

[crew.helper]
dir = "/work/other dir"
command = "codex"
TOML
}

@test "st lists teams and dry-runs one tab per agent" {
    _write_teams
    run _st --list
    assert_success
    assert_output --partial "crew"
    assert_output --partial "lead, helper"

    run _st crew --dry-run
    assert_success
    assert_line "[lead] cd /work/crew && claude --model opus '/lead plan it'"
    assert_line "[helper] cd '/work/other dir' && codex --model opus"
}

@test "st treats a team without agents as one agent named after it" {
    _write_teams
    cat >> "${CLAUDE_TEAM_CONFIG}" <<'TOML'

[solo]
dir = "/work/solo"
TOML
    run _st --list
    assert_success
    assert_line --regexp '^solo +/work/solo +solo$'

    run _st solo --dry-run
    assert_success
    assert_output "[solo] cd /work/solo && claude"
}

@test "st rejects an unknown team and a missing teams file" {
    _write_teams
    run _st nope --dry-run
    assert_failure
    assert_output --partial "no team, agent, or directory 'nope'"

    CLAUDE_TEAM_CONFIG="${TEST_TMPDIR}/missing.toml" run _st --list
    assert_failure
    assert_output --partial "no teams file"
    assert_output --partial "copy ~/.config/claude-team/teams.toml.example there"

    CLAUDE_TEAM_CONFIG="${TEST_TMPDIR}/missing.toml" run _st crew --dry-run
    assert_failure
    assert_output --partial "copy ~/.config/claude-team/teams.toml.example there"
}

@test "st dry-runs every team in the tracked teams.toml.example" {
    export CLAUDE_TEAM_CONFIG="${PROJECT_ROOT}/stow/desktop.darwin/.config/claude-team/teams.toml.example"
    run _st --list
    assert_success
    local team
    for team in $(awk '{print $1}' <<< "${output}"); do
        run _st "${team}" --dry-run
        assert_success
        assert_output --partial "] cd "
    done
}

@test "st agents inherit the team's prompt" {
    export CLAUDE_TEAM_CONFIG="${TEST_TMPDIR}/teams.toml"
    cat > "${CLAUDE_TEAM_CONFIG}" <<'TOML'
[pair]
prompt = "be the lead"

[pair.a]
dir = "/work/a"

[pair.b]
dir = "/work/b"
prompt = "be b"
TOML
    run _st pair --dry-run
    assert_success
    assert_line "[a] cd /work/a && claude 'be the lead'"
    assert_line "[b] cd /work/b && claude 'be b'"
}

@test "st opens one agent by name, with its team's settings" {
    _write_teams
    run _st helper --dry-run
    assert_success
    assert_output "[helper] cd '/work/other dir' && codex --model opus"

    run _st crew/lead --dry-run
    assert_success
    assert_output "[lead] cd /work/crew && claude --model opus '/lead plan it'"

    run _st crew/nope --dry-run
    assert_failure
    assert_output --partial "no team, agent, or directory 'crew/nope'"

    run _st nope/nope --dry-run
    assert_failure
    assert_output --partial "no team, agent, or directory 'nope/nope'"
}

@test "st asks for TEAM/AGENT when an agent name is in two teams" {
    _write_teams
    cat >> "${CLAUDE_TEAM_CONFIG}" <<'TOML'

[other]
dir = "/work/other"

[other.lead]
TOML
    run _st lead --dry-run
    assert_failure
    assert_output --partial "pick one: crew/lead, other/lead"

    run _st other/lead --dry-run
    assert_success
    assert_output "[lead] cd /work/other && claude"
}

@test "st prefers an agent over a directory of the same name" {
    _write_teams
    mkdir -p "${TEST_TMPDIR}/helper"
    cd "${TEST_TMPDIR}"
    run _st helper --dry-run
    assert_success
    assert_output --partial "[helper] cd '/work/other dir'"
}

@test "st runs each tab's command as the tab's program, not typed text" {
    run python3 - "${PROJECT_ROOT}/stow/desktop.darwin/.local/bin/st" <<'PY'
import importlib.machinery, importlib.util, os, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("st", sys.argv[1])
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("st", loader))
loader.exec_module(mod)
os.environ["SHELL"] = "/bin/zsh"
print(mod.tab_command("cd /work && claude"))
PY
    assert_success
    assert_output "/bin/zsh -lic 'cd /work && claude; exec /bin/zsh -il'"
}

@test "st opens Claude Code in a directory, even without a teams file" {
    mkdir -p "${TEST_TMPDIR}/my project"
    CLAUDE_TEAM_CONFIG="${TEST_TMPDIR}/missing.toml" run _st "${TEST_TMPDIR}/my project/" --dry-run
    assert_success
    assert_output "[my project] cd '$(cd "${TEST_TMPDIR}/my project" && pwd -P)' && claude"
}

@test "st prefers a team over a directory of the same name" {
    _write_teams
    mkdir -p "${TEST_TMPDIR}/crew"
    cd "${TEST_TMPDIR}"
    run _st crew --dry-run
    assert_success
    assert_line --partial "[lead] cd /work/crew"
}

@test "st with no arguments opens Claude Code in the current directory" {
    mkdir -p "${TEST_TMPDIR}/here"
    cd "${TEST_TMPDIR}/here"
    CLAUDE_TEAM_CONFIG="${TEST_TMPDIR}/missing.toml" run _st --dry-run
    assert_success
    assert_output "[here] cd $(pwd -P) && claude"
}

setup_firetv_sandbox() {
    FIRETV="${PROJECT_ROOT}/stow/personal/.local/bin/firetv"
    export FIRETV_STATE="${TEST_TMPDIR}/tv"
    export FIRETV_STATE_DIR="${TEST_TMPDIR}/state"
    # Never the real Pi-hole: this ph refuses until setup_firetv_pihole replaces it.
    export PH_BIN="${BIN_SANDBOX}/ph"
    export FIRETV_TWEAKS_FILE="${TEST_TMPDIR}/no-tweaks"
    printf '%s\n' '#!/usr/bin/env bash' \
        "printf 'ph: no password: run '\\''ph login'\\'' or set PIHOLE_PASSWORD\\n' >&2" 'exit 1' > "${PH_BIN}"
    chmod +x "${PH_BIN}"
    mkdir -p "${FIRETV_STATE}"
    # The TV: installed packages and disabled ones, one per line.
    printf '%s\n' com.amazon.tv.acr com.amazon.device.metrics com.amazon.device.metrics \
        com.amazon.storm.lightning.tutorial com.amazon.tv.launcher > "${FIRETV_STATE}/installed"
    printf '%s\n' com.amazon.storm.lightning.tutorial > "${FIRETV_STATE}/disabled"
    cat > "${BIN_SANDBOX}/adb" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FIRETV_STATE}/calls.log"
[[ "${1:-}" == -s ]] && shift 2
# Like real adb shell, drain stdin.
[[ "${1:-}" != shell ]] || cat > /dev/null
if [[ "$*" == "shell pm list packages"* && -e "${FIRETV_STATE}/pm-broken" ]]; then
    printf 'cmd: Failure calling service package\n'
    exit 20
fi
case "$*" in
    "connect "*) printf 'connected to %s\n' "${2}" ;;
    get-state)
        if [[ -e "${FIRETV_STATE}/offline" ]]; then printf 'offline\n'; else printf '%s\n' "${ADB_STATE:-device}"; fi ;;
    "disconnect "*) rm -f "${FIRETV_STATE}/offline" ;;
    "shell getprop ro.product.model") printf 'AFTDEC012E\r\n' ;;
    "shell getprop ro.build.version.name") printf 'Fire OS 8.1.8.5 (RS8185/3885)\r\n' ;;
    "shell pm list packages -d") sed 's/^/package:/' "${FIRETV_STATE}/disabled" ;;
    "shell pm list packages"*) sed 's/^/package:/' "${FIRETV_STATE}/installed" ;;
    # Settings as "NAMESPACE KEY VALUE" lines, the last one winning; "-" deletes.
    "shell settings put "*) printf '%s %s %s\n' "$4" "$5" "$6" >> "${FIRETV_STATE}/settings" ;;
    "shell settings delete "*) printf '%s %s -\n' "$4" "$5" >> "${FIRETV_STATE}/settings" ;;
    "shell settings get "*)
        value="$(awk -v ns="$4" -v k="$5" '$1 == ns && $2 == k { v = $3 } END { print v }' "${FIRETV_STATE}/settings" 2>/dev/null || true)"
        [[ "${value}" != - ]] || value=""
        printf '%s\r\n' "${value:-null}" ;;
    "shell settings list "*)
        awk -v ns="$4" '$1 == ns { if (!($2 in v)) o[++n] = $2; v[$2] = $3 } END { for (i = 1; i <= n; i++) if (v[o[i]] != "-") printf "%s=%s\r\n", o[i], v[o[i]] }' \
            "${FIRETV_STATE}/settings" 2>/dev/null || true ;;
    "shell df -k /data")
        printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\r\n/dev/block/dm-17 9339420 2299140 %s 26%% /data\r\n' \
            "$(cat "${FIRETV_STATE}/free" 2>/dev/null || printf 6892824)" ;;
    "shell pm trim-caches 999G") printf '%s\n' "$(( $(cat "${FIRETV_STATE}/free" 2>/dev/null || printf 6892824) + 204800 ))" > "${FIRETV_STATE}/free" ;;
    "shell dumpsys package com.amazon.venezia") printf '  Package [com.amazon.venezia]\r\n    userId=10171\r\n' ;;
    "shell dumpsys package "*) printf 'Unable to find package\r\n' ;;
    "shell pm path com.amazon.venezia")
        printf 'package:/system_ext/priv-app/com.amazon.venezia/com.amazon.venezia.apk\r\n' ;;
    "shell pm path com.amazon.ftvads.deeplinking")
        printf 'package:/system_ext/app/FtvAds/FtvAds.apk\r\n' ;;
    "shell pm path com.amazon.tv.acr") printf 'package:/system_ext/app/Acr/Acr.apk\r\n' ;;
    "shell pm path "*) ;;
    *"for a in /system_ext/priv-app/com.amazon.venezia/com.amazon.venezia.apk;"*"strings -n 6"*)
        printf '%s\r\n' appstore-tv-prod-na.amazon.com unagi-na.amazon.com 0com.amazon.dev \
            https://juggler.amazon.com ec2.eu-west-1.amazonaws.com ec2.us-east-1.amazonaws.com ;;
    *"for a in /system_ext/app/FtvAds/FtvAds.apk;"*"strings -n 6"*)
        printf '%s\r\n' mads.amazon.com aax-us-east.amazon-adsystem.com api.amazon.com never-looked-up.amazon.com ;;
    *"strings -n 6"*) exit 1 ;;
    *"/proc/net/tcp"*)
        [[ "$*" == *"-v u=10171 "* ]] || exit 1
        # 54.167.177.211:443 mapped into IPv6, then loopback, which drops.
        printf '%s\r\n' 0000000000000000FFFF0000D3B1A736:01BB 0100007F:1F90 ;;
    "shell pm disable-user --user 0 com.amazon.device.metrics")
        printf 'java.lang.SecurityException: Shell cannot change component state\n' ;;
    "shell pm disable-user --user 0 "*)
        printf '%s\n' "${6}" >> "${FIRETV_STATE}/disabled"
        printf 'Package %s new state: disabled-user\r\n' "${6}" ;;
    "shell pm enable "*)
        grep -vxF "${4}" "${FIRETV_STATE}/disabled" > "${FIRETV_STATE}/d.tmp" || true
        mv "${FIRETV_STATE}/d.tmp" "${FIRETV_STATE}/disabled"
        printf 'Package %s new state: enabled\n' "${4}" ;;
    *) printf 'adb %s\n' "$*" ;;
esac
MOCK
    chmod +x "${BIN_SANDBOX}/adb"
}

@test "firetv shows help and rejects bad commands and groups" {
    run "${PROJECT_ROOT}/stow/personal/.local/bin/firetv" --help
    assert_success
    assert_output --partial "disable TARGET..."
    run "${PROJECT_ROOT}/stow/personal/.local/bin/firetv"
    assert_failure 2
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" bogus
    assert_failure
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable
    assert_failure
    assert_output --partial "Name a group (telemetry, ads, bloat, all) or a package"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable nope
    assert_failure
    assert_output --partial "Unknown group or package: nope"
    [[ ! -e "${FIRETV_STATE}/calls.log" ]]
}

@test "firetv stops when the TV has not authorized this machine" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" ADB_STATE="error: device unauthorized" "${FIRETV}" list
    assert_failure
    assert_output --partial "Accept the prompt on the TV"
}

@test "firetv list reports enabled, disabled, and absent packages" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --host 10.0.0.5 list bloat telemetry
    assert_success
    assert_line --regexp '^enabled +telemetry +com\.amazon\.tv\.acr '
    assert_line --regexp '^disabled +bloat +com\.amazon\.storm\.lightning\.tutorial '
    assert_line --regexp '^absent +telemetry +com\.amazon\.perfc '
    run grep -c -- '-s 10.0.0.5:5555' "${FIRETV_STATE}/calls.log"
    refute_output "0"
}

@test "firetv has no separate status or disabled command" {
    setup_firetv_sandbox
    for cmd in status disabled; do
        run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" "${cmd}"
        assert_failure
        assert_output --partial "Unknown command: ${cmd}"
    done
}

@test "firetv disable tries every package, skipping absent, done, and root-only ones" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --dry-run disable telemetry
    assert_success
    assert_output --partial "would disable com.amazon.tv.acr"
    run grep -- 'disable-user' "${FIRETV_STATE}/calls.log"
    assert_failure

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable all all telemetry
    assert_success
    assert_output --partial "com.amazon.device.metrics: needs root"
    assert_output --partial "com.amazon.storm.lightning.tutorial: already disabled"
    assert_output --partial "com.amazon.perfc: not on this TV"
    assert_output --partial "1 disabled, 16 skipped, 1 need root, 0 failed"
    run grep -c -- 'disable-user' "${FIRETV_STATE}/calls.log"
    assert_output "2"
    run grep -cxF com.amazon.tv.launcher "${FIRETV_STATE}/disabled"
    assert_output "0"

    # A rerun changes nothing and still passes.
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable telemetry
    assert_success
    assert_output --partial "0 disabled"
    run grep -c -- 'disable-user' "${FIRETV_STATE}/calls.log"
    assert_output "3"
}

@test "firetv enables and disables single packages, and refuses to disable core ones" {
    setup_firetv_sandbox
    printf '%s\n' com.amazon.media.recommendations com.example.extra >> "${FIRETV_STATE}/installed"
    printf '%s\n' com.amazon.media.recommendations >> "${FIRETV_STATE}/disabled"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" enable com.amazon.media.recommendations
    assert_success
    assert_output --partial "com.amazon.media.recommendations: enabled ((not on the debloat list))"
    assert_output --partial "1 enabled, 0 skipped"
    run grep -cxF com.amazon.media.recommendations "${FIRETV_STATE}/disabled"
    assert_output "0"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable com.amazon.media.recommendations
    assert_failure
    assert_output --partial "com.amazon.media.recommendations is a core package the TV needs"
    run grep -c disable-user "${FIRETV_STATE}/calls.log"
    assert_output "0"

    # A package name beside a group is tried once, even when the group has it.
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable com.example.extra telemetry com.amazon.tv.acr
    assert_success
    assert_output --partial "com.example.extra: disabled"
    run grep -c 'disable-user --user 0 com.amazon.tv.acr$' "${FIRETV_STATE}/calls.log"
    assert_output "1"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable 'com.x;reboot'
    assert_failure
    assert_output --partial "Unknown group or package"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" list
    assert_success
    refute_output --partial "media.recommendations"
}

@test "firetv fails on an unexpected pm reply" {
    setup_firetv_sandbox
    printf '%s\n' com.amazon.gamehub >> "${FIRETV_STATE}/installed"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" enable bloat
    assert_success
    sed -i.bak 's/new state: enabled/Unknown package/' "${BIN_SANDBOX}/adb"
    printf '%s\n' com.amazon.gamehub >> "${FIRETV_STATE}/disabled"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" enable bloat
    assert_failure
    assert_output --partial "com.amazon.gamehub: Package com.amazon.gamehub Unknown package"
    assert_output --partial "1 failed"
}

@test "firetv reconnects a connection left offline by a reboot" {
    setup_firetv_sandbox
    touch "${FIRETV_STATE}/offline"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" connect
    assert_success
    assert_output --partial "AFTDEC012E, Fire OS 8.1.8.5 (RS8185/3885)"
    refute_output --partial "Fire OS Fire OS"
    run grep -c '^disconnect ' "${FIRETV_STATE}/calls.log"
    assert_output "1"
}

@test "firetv says why when the package list cannot be read" {
    setup_firetv_sandbox
    touch "${FIRETV_STATE}/pm-broken"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable ads
    assert_failure
    assert_output --partial "Could not list packages on the TV"
    run grep -- 'disable-user' "${FIRETV_STATE}/calls.log"
    assert_failure
}

@test "firetv rejects arguments to commands that take none" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" reboot now
    assert_failure
    assert_output --partial "reboot takes no arguments"
    [[ ! -e "${FIRETV_STATE}/calls.log" ]]
}

@test "firetv enable undoes a disable" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" enable bloat
    assert_success
    assert_output --partial "com.amazon.storm.lightning.tutorial: enabled"
    run cat "${FIRETV_STATE}/disabled"
    assert_output ""
}

@test "firetv backup saves the package list under its state dir" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" FIRETV_STATE_DIR="${TEST_TMPDIR}/backups" "${FIRETV}" backup
    assert_success
    run bash -c 'cat "$1"/packages-*.txt' _ "${TEST_TMPDIR}/backups"
    assert_line "package:com.amazon.tv.launcher"
}

@test "firetv doctor passes a debloated TV and remembers root-only packages" {
    setup_firetv_sandbox
    export FIRETV_STATE_DIR="${TEST_TMPDIR}/state"
    printf '%s\n' com.amazon.tv.launcher com.amazon.tv.settings.v2 >> "${FIRETV_STATE}/installed"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor
    assert_success
    assert_output --partial "AFTDEC012E, Fire OS 8.1.8.5"
    assert_output --partial "warning: telemetry: 0 of 2 disabled"
    assert_output --partial "- firetv disable telemetry"
    assert_output --partial "warning: No package backup yet"
    assert_output --partial "ok: ads: none on this TV"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" disable telemetry
    assert_success
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" backup
    assert_success
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor
    assert_success
    assert_output --partial "ok: telemetry: 1 of 2 disabled"
    assert_output --partial "warning: Need root, so still on: com.amazon.device.metrics; Pi-hole not checked"
    assert_output --partial "ok: Backup: ${FIRETV_STATE_DIR}/packages-"
    refute_output --partial "- firetv disable telemetry"
    run grep -- 'disable-user\|pm enable' "${FIRETV_STATE}/calls.log"
    assert_output --partial "com.amazon.tv.acr"
    run grep -c -- 'disable-user' "${FIRETV_STATE}/calls.log"
    assert_output "2"
}

@test "firetv doctor fails on a disabled core package and says how to restore it" {
    setup_firetv_sandbox
    printf '%s\n' com.amazon.tv.launcher >> "${FIRETV_STATE}/disabled"
    run env PATH="${BIN_SANDBOX}:${PATH}" FIRETV_STATE_DIR="${TEST_TMPDIR}/state" "${FIRETV}" doctor
    assert_failure
    assert_output --partial "failed: Core packages disabled: com.amazon.tv.launcher"
    assert_output --partial "adb -s 192.168.0.84:5555 shell pm enable com.amazon.tv.launcher"
}

@test "firetv doctor reports a missing adb or an unreachable TV without stopping silently" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" ADB_BIN=no-such-adb "${FIRETV}" doctor
    assert_failure
    assert_output --partial "failed: adb is not installed"
    assert_output --partial "brew install --cask android-platform-tools"

    run env PATH="${BIN_SANDBOX}:${PATH}" ADB_STATE="error: device unauthorized" "${FIRETV}" doctor
    assert_failure
    assert_output --partial "Accept the prompt on the TV"
    assert_output --partial "Failed: 1"
}

setup_firetv_pihole() {
    setup_firetv_sandbox
    export PIHOLE_STATE="${TEST_TMPDIR}/pihole"
    mkdir -p "${PIHOLE_STATE}" "${FIRETV_STATE_DIR}"
    printf '%s\n' com.amazon.ftvads.deeplinking >> "${FIRETV_STATE}/installed"
    printf '%s\n' com.amazon.ftvads.deeplinking com.amazon.device.metrics > "${FIRETV_STATE_DIR}/needs-root"
    printf '%s\n' mads.amazon.com > "${PIHOLE_STATE}/blocked"
    printf '%s\n' msh.amazon.com > "${PIHOLE_STATE}/denylist"
    : > "${PIHOLE_STATE}/calls.log"
    # ph's --json check and deny, against a deny list in a file.
    cat > "${PH_BIN}" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${PIHOLE_STATE}/calls.log"
[[ "${1:-}" == --json ]] || { printf 'ph: test expects --json\n' >&2; exit 1; }
shift
case "$1" in
    -n)
        [[ "$3" == queries && "$4" == 192.168.0.84 ]] || { printf 'ph: unexpected %s\n' "$*" >&2; exit 1; }
        jq -n '{queries: [
            {domain: "appstore-tv-prod-na.amazon.com", status: "FORWARDED"},
            {domain: "appstore-tv-prod-na.amazon.com", status: "CACHE"},
            {domain: "unagi-na.amazon.com", status: "GRAVITY"},
            {domain: "avs-alexa-19-na.amazon.com", status: "FORWARDED"},
            {domain: "mads.amazon.com", status: "GRAVITY"},
            {domain: "aax-us-east.amazon-adsystem.com", status: "FORWARDED"},
            {domain: "api.amazon.com", status: "CACHE"},
            {domain: "bad name;rm", status: "FORWARDED"}]}'
        ;;
    check)
        # A Pi-hole that rate-limits the first login for a domain.
        if [[ -n "${PH_LIMIT_ONCE:-}" && ! -e "${PIHOLE_STATE}/limited-$2" ]]; then
            touch "${PIHOLE_STATE}/limited-$2"
            printf 'ph: login failed: HTTP 429: Rate-limiting login attempts\n' >&2
            exit 1
        fi
        if grep -qxF "$2" "${PIHOLE_STATE}/blocked"; then
            printf '{"search":{"domains":[],"gravity":[{"domain":"%s","type":"block","enabled":true}]}}\n' "$2"
        else
            printf '{"search":{"domains":[],"gravity":[]}}\n'
        fi
        ;;
    list)
        [[ "$2" == deny ]] || { printf 'ph: unexpected %s\n' "$*" >&2; exit 1; }
        jq -R -s '{domains: (split("\n") | map(select(. != "")) | map({domain: ., kind: "exact", type: "deny", enabled: true}))}' \
            "${PIHOLE_STATE}/denylist"
        ;;
    deny)
        [[ "$2" == -c && -n "$3" ]] || { printf 'ph: test expects a comment\n' >&2; exit 1; }
        shift 3
        printf '%s\n' "$@" | tee -a "${PIHOLE_STATE}/blocked" > "${PIHOLE_STATE}/denied"
        printf '{"processed":{"success":[],"errors":[]}}\n'
        ;;
    *) printf 'ph: unexpected %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
    chmod +x "${PH_BIN}"
}

@test "firetv doctor passes on ph's error and says to log in" {
    setup_firetv_sandbox
    mkdir -p "${FIRETV_STATE_DIR}"
    printf '%s\n' com.amazon.ftvads.deeplinking > "${FIRETV_STATE_DIR}/needs-root"
    printf '%s\n' com.amazon.ftvads.deeplinking >> "${FIRETV_STATE}/installed"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "Pi-hole not checked: no password: run 'ph login'"
    assert_output --partial "- ph login"

    run env PATH="${BIN_SANDBOX}:${PATH}" PH_BIN=no-such-ph "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "Pi-hole not checked: ph not found"
}

@test "firetv doctor checks the hosts a needs-root package's code looks up and blocks nothing unasked" {
    setup_firetv_pihole
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "warning: com.amazon.ftvads.deeplinking needs root; Pi-hole does not block aax-us-east.amazon-adsystem.com"
    assert_output --partial "left alone, the TV needs them: api.amazon.com"
    assert_output --partial "warning: com.amazon.device.metrics needs root and has no hostnames in its code"
    assert_output --partial "- firetv --watch 120 domains com.amazon.device.metrics"
    assert_output --partial "- ph deny aax-us-east.amazon-adsystem.com"
    refute_output --partial "never-looked-up"
    # Only the allowed, non-kept host needs a fresh check; mads is blocked in the log.
    run grep -- '--json check' "${PIHOLE_STATE}/calls.log"
    assert_output "--json check aax-us-east.amazon-adsystem.com"
    run grep -c -- '--json deny' "${PIHOLE_STATE}/calls.log"
    assert_output "0"
}

@test "firetv doctor blocks the unblocked hosts through ph when told yes, then passes" {
    setup_firetv_pihole
    run bash -c 'printf "1\n" | env PATH="$1" DOTFILES_PROMPT=read "$2" doctor' _ "${BIN_SANDBOX}:${PATH}" "${FIRETV}"
    assert_success
    assert_output --partial "Pi-hole now blocks aax-us-east.amazon-adsystem.com"
    run cat "${PIHOLE_STATE}/denied"
    assert_output "aax-us-east.amazon-adsystem.com"

    # The log still says allowed; the fresh check sees the new block.
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "ok: com.amazon.ftvads.deeplinking needs root; Pi-hole blocks what the TV looks up from its code: mads.amazon.com aax-us-east.amazon-adsystem.com"
    refute_output --partial "- ph deny"
}

@test "firetv doctor carries on when a needs-root package's code cannot be read" {
    setup_firetv_pihole
    printf '%s\n' com.amazon.tv.acr > "${FIRETV_STATE_DIR}/needs-root"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "warning: com.amazon.tv.acr needs root and has no hostnames in its code"
    assert_output --partial "Passed: "
}

@test "firetv doctor fails when the Pi-hole denies a host the TV needs" {
    setup_firetv_pihole
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "ok: Pi-hole denies none of the hosts the TV needs"

    printf '%s\n' ktpx.amazon.com >> "${PIHOLE_STATE}/denylist"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_failure
    assert_output --partial "failed: Pi-hole denies hosts the TV needs: ktpx.amazon.com"
    assert_output --partial "- ph undeny ktpx.amazon.com"
}

@test "firetv doctor fails when ph cannot add the domains" {
    setup_firetv_pihole
    sed -i.bak 's/"errors":\[\]/"errors":[{"item":"aax.amazon-adsystem.com","error":"UNIQUE constraint failed"}]/' "${PH_BIN}"
    run bash -c 'printf "1\n" | env PATH="$1" DOTFILES_PROMPT=read "$2" doctor' _ "${BIN_SANDBOX}:${PATH}" "${FIRETV}"
    assert_failure
    assert_output --partial "Pi-hole did not block them: aax.amazon-adsystem.com: UNIQUE constraint failed"
}

@test "firetv domains needs one plain package name" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" domains
    assert_failure
    assert_output --partial "domains takes one package"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" domains 'com.x;reboot'
    assert_failure
    assert_output --partial "Not a package name"
    [[ ! -e "${FIRETV_STATE}/calls.log" ]]
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --watch soon domains com.amazon.venezia
    assert_failure
    assert_output --partial "--watch needs a number of seconds"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --watch 0 domains com.amazon.nope
    assert_failure
    assert_output --partial "com.amazon.nope is not on this TV"
}

@test "firetv domains lists the built-in hosts the TV looked up and names its connections" {
    setup_firetv_pihole
    cat > "${BIN_SANDBOX}/dig" <<'MOCK'
#!/usr/bin/env bash
case "${*: -1}" in
    avs-alexa-19-na.amazon.com) printf 'avs-lb.amazon.com.\n54.167.177.211\n' ;;
    appstore-tv-prod-na.amazon.com) printf '52.1.2.3\n' ;;
esac
MOCK
    chmod +x "${BIN_SANDBOX}/dig"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --watch 1 domains com.amazon.venezia < /dev/null
    assert_success
    assert_output --partial "com.amazon.venezia (app ID 10171)"
    assert_output --partial "looked up by the TV (2 of 4)"
    assert_line --regexp '^  appstore-tv-prod-na\.amazon\.com +allowed +2 lookups$'
    assert_line --regexp '^  unagi-na\.amazon\.com +blocked +1 lookups$'
    assert_output --partial "2 more never looked up; --all lists them"
    refute_output --partial "com.amazon.dev"
    refute_output --partial "eu-west-1"
    assert_line --regexp '^  54\.167\.177\.211:443 +avs-alexa-19-na\.amazon\.com$'
    refute_output --partial "127.0.0.1"
    run grep -c -- '--json check' "${PIHOLE_STATE}/calls.log"
    assert_output "0"

    run env PATH="${BIN_SANDBOX}:${PATH}" PH_LIMIT_ONCE=1 "${FIRETV}" --all --watch 0 domains com.amazon.venezia < /dev/null
    assert_success
    assert_output --partial "Built in, never looked up"
    assert_line --regexp '^  ec2\.us-east-1\.amazonaws\.com +not blocked$'
    assert_line --regexp '^  juggler\.amazon\.com +not blocked$'
    refute_output --regexp ' \?$'
    refute_output --partial "Connections in"
}

@test "firetv domains lists built-in hosts plainly without a Pi-hole log" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --watch 0 domains com.amazon.venezia < /dev/null
    assert_success
    assert_output --partial "No Pi-hole log (ph login?)"
    assert_line "  appstore-tv-prod-na.amazon.com"
    assert_line "  juggler.amazon.com"
}

@test "firetv animations shows, speeds up, and restores Android's animation scales" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" animations
    assert_success
    assert_line --regexp '^  animator_duration_scale +1 \(default\)$'
    run grep -c 'settings put' "${FIRETV_STATE}/calls.log"
    assert_output "0"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" animations fast
    assert_success
    assert_line --regexp '^  window_animation_scale +0\.5$'
    assert_line --regexp '^  transition_animation_scale +0\.5$'
    assert_line --regexp '^  animator_duration_scale +0\.5$'
    assert_output --partial "Animations set to fast (0.5x)"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" animations normal
    assert_success
    assert_line --regexp '^  window_animation_scale +1$'

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" animations ludicrous
    assert_failure
    assert_output --partial "animations takes fast or normal"
}

@test "firetv tweak saves what it replaces and off restores it, unset included" {
    setup_firetv_sandbox
    printf '%s\n' 'global wifi_scan_always_enabled 1' > "${FIRETV_STATE}/settings"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweaks
    assert_success
    assert_line --regexp '^  no-wifi-scan +off +No Wi-Fi scanning'
    assert_line --regexp '^  fast-animations +off +Animations at 0\.5x$'

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak no-wifi-scan on
    assert_success
    assert_output --partial "global wifi_scan_always_enabled: 1 -> 0"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak no-ble-scan on
    assert_success
    assert_output --partial "global ble_scan_always_enabled: null -> 0"
    # A second on keeps the first saved value.
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak no-wifi-scan on
    assert_success
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweaks
    assert_line --regexp '^  no-wifi-scan +on '

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak no-wifi-scan off
    assert_success
    assert_output --partial "global wifi_scan_always_enabled: 0 -> 1 (restored)"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak no-ble-scan off
    assert_success
    run grep -c 'settings delete global ble_scan_always_enabled' "${FIRETV_STATE}/calls.log"
    assert_output "1"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak no-ble-scan off
    assert_success
    assert_output --partial "no saved value; left at null"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak warp-speed on
    assert_failure
    assert_output --partial "Unknown tweak: warp-speed"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak no-ble-scan maybe
    assert_failure
    assert_output --partial "Use: firetv tweak NAME on|off"
}

@test "firetv tweaks reads your tweaks file and skips unsafe lines" {
    setup_firetv_sandbox
    export FIRETV_TWEAKS_FILE="${TEST_TMPDIR}/tweaks"
    printf '%s\n' '# my tweaks' $'quiet-home\tsecure\tftv_autoplay\t0\tNo autoplay on Home' \
        $'evil\tglobal\tx\t1;reboot\tNope' $'bad-ns\tvendor\tx\t1\tNope' > "${FIRETV_TWEAKS_FILE}"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweaks
    assert_success
    assert_line --regexp '^  quiet-home +off +No autoplay on Home$'
    assert_output --partial "Skipping tweak line: evil global x 1;reboot"
    assert_output --partial "Skipping tweak line: bad-ns vendor"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" tweak quiet-home on
    assert_success
    run grep -c 'settings put secure ftv_autoplay 0' "${FIRETV_STATE}/calls.log"
    assert_output "1"
    run grep -c reboot "${FIRETV_STATE}/calls.log"
    assert_output "0"
}

@test "firetv settings-diff shows what changed between two runs and suggests tweak lines" {
    setup_firetv_sandbox
    printf '%s\n' 'secure ftv_autoplay 1' 'global stay_on 0' 'system font_scale 1.0' > "${FIRETV_STATE}/settings"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" settings-diff
    assert_success
    assert_output --partial "Saved 3 settings"
    assert_output --partial "run firetv settings-diff again"

    printf '%s\n' 'secure ftv_autoplay 0' 'global new_key on' 'system font_scale -' >> "${FIRETV_STATE}/settings"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" settings-diff
    assert_success
    assert_line --regexp '^  changed +secure +ftv_autoplay +1 -> 0$'
    assert_line --regexp '^  added +global +new_key +\(unset\) -> on$'
    assert_line --regexp '^  removed +system +font_scale +1\.0 -> \(unset\)$'
    assert_line "$(printf 'my-tweak\tsecure\tftv_autoplay\t0\tDescribe it')"
    refute_output --partial $'my-tweak\tsystem'
    [[ ! -e "${FIRETV_STATE_DIR}/settings-snapshot" ]]

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" settings-diff
    assert_success
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" settings-diff reset
    assert_success
    [[ ! -e "${FIRETV_STATE_DIR}/settings-snapshot" ]]
}

@test "firetv clean trims caches, and doctor warns when storage is low" {
    setup_firetv_sandbox
    printf '%s\n' 512000 > "${FIRETV_STATE}/free"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "warning: Storage low: 500 MB free"
    assert_output --partial "- firetv clean"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" clean
    assert_success
    assert_output --partial "App caches trimmed: 200 MB freed, 700 MB free"

    printf '%s\n' 6892824 > "${FIRETV_STATE}/free"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_output --partial "ok: Storage: 6731 MB free"
}
