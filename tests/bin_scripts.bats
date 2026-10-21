#!/usr/bin/env bats
# Tests for the stow/*/.local/bin scripts other than the Pi-hole ones, firetv, ai-doctor, and ph: isolated smoke and behavior coverage.

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
# remote command locally as that home. Git ignores the real home's config, whose commit
# signing would be slow or prompt.
df_deploy_sandbox() {
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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
    python3 "${PROJECT_ROOT}/stow/desktop/.local/bin/st" "$@"
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
    export CLAUDE_TEAM_CONFIG="${PROJECT_ROOT}/stow/desktop/.config/claude-team/teams.toml.example"
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
    run python3 - "${PROJECT_ROOT}/stow/desktop/.local/bin/st" <<'PY'
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
