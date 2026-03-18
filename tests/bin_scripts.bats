#!/usr/bin/env bats
# Tests for dot_local/bin scripts — isolated smoke and behavior coverage.

load test_helper

setup() {
    setup_tmpdir
    export BIN_SANDBOX="${TEST_TMPDIR}/bin"
    mkdir -p "${BIN_SANDBOX}"
    ln -sf "$(brew --prefix)/bin/bash" "${BIN_SANDBOX}/bash"
}

teardown() {
    teardown_tmpdir
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
        { print }
    ' "${source_script}" > "${probe_script}"

    chmod +x "${probe_script}"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" "${probe_script}"
}

@test "ph-padd displays help" {
    run sh "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-padd" --help
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

    run_padd_api_probe "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-padd"
    assert_failure
    assert_output --partial "API not available at: localhost"

    run cat "${TEST_TMPDIR}/ph-padd-dig-args"
    assert_success
    assert_output --partial "+time=2"
    assert_output --partial "+tries=1"
}

@test "os-update displays help" {
    run "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_os-update" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "os-update"
    assert_output --partial "package-manager updates"
}

@test "os-update runs linux apt and Homebrew updates" {
    mkdir -p "${TEST_TMPDIR}/brew-cache-linux"

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
    printf '%s\n' "${TEST_TMPDIR}/brew-cache-linux"
    exit 0
fi

printf 'brew %s\n' "$*"
MOCK

    chmod +x "${BIN_SANDBOX}/sudo" "${BIN_SANDBOX}/apt-get" "${BIN_SANDBOX}/brew"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_os-update"
    assert_success
    assert_output --partial "sudo apt-get update"
    assert_output --partial "sudo apt-get full-upgrade -y"
    assert_output --partial "sudo apt-get autoremove --purge -y"
    assert_output --partial "sudo apt-get autoclean -y"
    assert_output --partial "brew update"
    assert_output --partial "brew upgrade"
    assert_output --partial "brew cleanup --prune=all"
    [[ ! -d "${TEST_TMPDIR}/brew-cache-linux" ]]
}

@test "os-update runs macOS system and Homebrew updates" {
    mkdir -p "${TEST_TMPDIR}/Applications/Xcode.app"
    mkdir -p "${TEST_TMPDIR}/brew-cache-macos"

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
    printf '%s\n' "${TEST_TMPDIR}/brew-cache-macos"
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_os-update"
    assert_success
    assert_output --partial "sudo softwareupdate --install --all"
    assert_output --partial "mas upgrade"
    assert_output --partial "sudo xcodebuild -license accept"
    assert_output --partial "brew update"
    assert_output --partial "brew upgrade"
    assert_output --partial "brew cleanup --prune=all"
    [[ ! -d "${TEST_TMPDIR}/brew-cache-macos" ]]
}

@test "ph-update displays help" {
    run "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-update" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "ph-update"
    assert_output --partial "Run os-update, refresh Pi-hole, and update PADD"
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-update"
    assert_success
    assert_output --partial "sudo apt-get update"
    assert_output --partial "sudo PATH=${BIN_SANDBOX}:/usr/bin:/bin"
    assert_output --partial "PH_UPDATE_SKIP_OS_UPDATE=1"
    assert_output --partial "executable_ph-update"
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-update"
    assert_failure
    assert_output --partial "pihole command is unavailable"
    [[ "${output}" != *"sudo apt-get update"* ]]
}

@test "ph-test displays help" {
    run "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-test" --help
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-test" 192.0.2.53
    assert_success
    assert_output --partial "sudo PATH=${BIN_SANDBOX}:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
    assert_output --partial "executable_ph-test 192.0.2.53"
}

@test "ph-test finds unbound commands through supplemental sbin paths" {
    local unbound_sbin="${TEST_TMPDIR}/unbound-sbin"
    mkdir -p "${unbound_sbin}"

    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

path_assignment="${1}"
script_path="${2}"
shift 2

export PATH="${path_assignment#PATH=}"

tmp_script="$(mktemp)"
awk '
    /^# Self-elevate if not root \(preserve PATH for ~\/\.local\/bin commands\)$/ { skip=1; next }
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-test"
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

path_assignment="${1}"
script_path="${2}"
shift 2

export PATH="${path_assignment#PATH=}"

tmp_script="$(mktemp)"
awk '
    /^# Self-elevate if not root \(preserve PATH for ~\/\.local\/bin commands\)$/ { skip=1; next }
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-test"
    assert_success
    assert_output --partial "UNBOUND_CONF=${primary_conf}"
    assert_output --partial "interface=127.0.0.1"
    assert_output --partial "hide-version=yes"
}

@test "ts-test displays help" {
    run bash "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ts-test" --help
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
        bash "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ts-test"
    assert_success
    assert_output --partial "Platform: Linux"
    assert_output --partial "Backend: Running"
    assert_output --partial "Summary"
    assert_output --partial "All checks passed."
}

@test "sshkey displays help" {
    run env HOME="${TEST_TMPDIR}/home" PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" --help
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" create devkey
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" create
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" create -m home
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" cleanup -y
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" cleanup --dry-run
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" doctor
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" doctor
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" doctor
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" doctor
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
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" doctor
    assert_failure
    assert_output --partial "~/.ssh permissions OK"
    refute_output --partial "Bad private key permissions"
    refute_output --partial "Bad public key permissions"
}
