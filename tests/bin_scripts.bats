#!/usr/bin/env bats
# Tests for dot_local/bin scripts — isolated smoke and behavior coverage.

load test_helper

setup() {
    setup_tmpdir
    export BIN_SANDBOX="${TEST_TMPDIR}/bin"
    mkdir -p "${BIN_SANDBOX}"
}

teardown() {
    teardown_tmpdir
}

@test "ph-padd displays help" {
    run sh "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-padd" --help
    assert_success
    assert_output --partial "PADD displays stats about your Pi-hole"
    assert_output --partial "--json"
}

@test "ph-padd-unbound displays help" {
    run sh "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-padd-unbound" --help
    assert_success
    assert_output --partial "PADD displays stats about your Pi-hole"
    assert_output --partial "--json"
}

@test "ph-update self-elevates through sudo when not root" {
    cat > "${BIN_SANDBOX}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*"
MOCK
    chmod +x "${BIN_SANDBOX}/sudo"

    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" \
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_ph-update"
    assert_success
    assert_output --partial "sudo PATH=${BIN_SANDBOX}:/usr/bin:/bin"
    assert_output --partial "executable_ph-update"
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

@test "ts-test completes successfully in an isolated mocked environment" {
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
    assert_output --partial "Tailscale Test Suite"
    assert_output --partial "All tests passed!"
}

@test "sshkey displays help" {
    run env HOME="${TEST_TMPDIR}/home" PATH="/usr/bin:/bin" \
        "${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_sshkey" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "sshkey create <name>"
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
