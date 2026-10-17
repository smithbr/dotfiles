#!/usr/bin/env bats
# Tests for bootstrap scripts — guard clauses, idempotency checks, and
# structural validation. No system packages are installed; we only verify
# the decision logic.

load test_helper

setup() {
    setup_tmpdir
}

teardown() {
    teardown_tmpdir
}

# ---------------------------------------------------------------------------
# linux/setup.sh — apt-packages.txt validation
# ---------------------------------------------------------------------------

@test "apt-packages.txt exists and is non-empty" {
    local pkg_file="${PROJECT_ROOT}/scripts/bootstrap/linux/apt-packages.txt"
    [[ -f "${pkg_file}" ]]
    [[ -s "${pkg_file}" ]]
}

@test "apt-packages.txt contains no blank entries after filtering" {
    run bash -c '
        count=0
        while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
            [[ -z "${pkg}" ]] && continue
            [[ "${pkg}" == \#* ]] && continue
            count=$((count + 1))
        done < "'"${PROJECT_ROOT}/scripts/bootstrap/linux/apt-packages.txt"'"
        echo "${count}"
    '
    assert_success
    # Should have at least one actual package
    [[ "${output}" -gt 0 ]]
}

@test "apt-packages.txt has no duplicate packages" {
    run bash -c '
        filtered_packages="$(mktemp)"
        while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
            [[ -z "${pkg}" ]] && continue
            [[ "${pkg}" == \#* ]] && continue
            printf "%s\n" "${pkg}" >> "${filtered_packages}"
        done < "'"${PROJECT_ROOT}/scripts/bootstrap/linux/apt-packages.txt"'"
        duplicate="$(sort "${filtered_packages}" | uniq -d | head -n 1)"
        rm -f "${filtered_packages}"
        if [[ -n "${duplicate}" ]]; then
            echo "DUPLICATE: ${duplicate}"
            exit 1
        fi
        echo "NO_DUPLICATES"
    '
    assert_success
    assert_output "NO_DUPLICATES"
}

# ---------------------------------------------------------------------------
# linux/setup.sh — apt-get guard clause
# ---------------------------------------------------------------------------

@test "linux setup.sh skips gracefully when apt-get is absent" {
    # Use a PATH that has basic tools but NOT apt-get
    mkdir -p "${TEST_TMPDIR}/bin"
    ln -sf "$(command -v bash)" "${TEST_TMPDIR}/bin/bash"
    ln -sf "$(command -v echo)" "${TEST_TMPDIR}/bin/echo"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"

        if ! command -v apt-get >/dev/null 2>&1; then
            echo "SKIPPED"
            exit 0
        fi
        echo "CONTINUED"
    '
    assert_success
    assert_output "SKIPPED"
}

@test "linux setup.sh installs only missing base packages" {
    run bash -c '
        set -euo pipefail

        export TEST_ROOT="'"${TEST_TMPDIR}"'/linux-bootstrap-missing-apt"
        export TEST_BOOTSTRAP_DIR="${TEST_ROOT}/bootstrap"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_ROOT}/apt.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export BOOTSTRAP_DIR="${TEST_BOOTSTRAP_DIR}"

        mkdir -p "${TEST_BOOTSTRAP_DIR}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        printf "curl\ngit\nzsh\n" > "${TEST_BOOTSTRAP_DIR}/apt-packages.txt"

        cat > "${TEST_BOOTSTRAP_DIR}/docker.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL docker" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/tailscale.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL tailscale" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/apt-get" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "apt-get $*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/sudo" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
"$@"
MOCK

        cat > "${TEST_BIN}/dpkg-query" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
shift 2
for pkg in "$@"; do
    case "${pkg}" in
        curl|zsh)
            printf "%s\tinstall ok installed\n" "${pkg}"
            ;;
    esac
done
MOCK

        chmod +x "${TEST_BOOTSTRAP_DIR}/docker.sh" \
            "${TEST_BOOTSTRAP_DIR}/tailscale.sh" \
            "${TEST_BIN}/apt-get" \
            "${TEST_BIN}/sudo" \
            "${TEST_BIN}/dpkg-query"

        cd "'"${PROJECT_ROOT}"'"
        printf "n\nn\n" | ./scripts/bootstrap/linux/setup.sh

        grep -qx "apt-get update" "${TEST_LOG}" || { echo "missing apt update"; exit 1; }
        grep -qx "apt-get install -y git" "${TEST_LOG}" || { echo "missing missing-only install"; exit 1; }
        if grep -q "curl" "${TEST_LOG}" || grep -q "zsh" "${TEST_LOG}"; then
            echo "installed packages should not be reinstalled"
            exit 1
        fi
    '
    assert_success
    assert_output --partial "Installing base Linux packages: git"
}

# ---------------------------------------------------------------------------
# linux/docker.sh — idempotency guard
# ---------------------------------------------------------------------------

# Runs a vendor install script (docker.sh, tailscale.sh) with a scratch HOME
# and Homebrew prefix, no apt-get, and only the mocks in TEST_TMPDIR/bin on
# PATH; $1 prepares them.
_run_vendor_script() {
    local script="$1"
    run bash -c '
        export HOME="'"${TEST_TMPDIR}"'/home" HOMEBREW_PREFIX="'"${TEST_TMPDIR}"'/brew"
        export PATH="'"${TEST_TMPDIR}"'/bin:/usr/bin:/bin"
        mkdir -p "${HOME}" "'"${TEST_TMPDIR}"'/bin"
        '"$2"'
        "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/'"${script}"'"
    '
}

@test "docker.sh skips when docker is on PATH, or came through Homebrew" {
    _run_vendor_script docker.sh 'printf "#!/bin/sh\n" > "'"${TEST_TMPDIR}"'/bin/docker"; chmod +x "'"${TEST_TMPDIR}"'/bin/docker"'
    assert_success
    assert_output --partial "Docker already installed, skipping"

    _run_vendor_script docker.sh 'mkdir -p "${HOMEBREW_PREFIX}/bin"; printf "#!/bin/sh\n" > "${HOMEBREW_PREFIX}/bin/docker"; chmod +x "${HOMEBREW_PREFIX}/bin/docker"'
    assert_success
    assert_output --partial "Docker already installed, skipping"

    # Neither: on a box without apt-get the install stops there.
    _run_vendor_script docker.sh 'rm -f "'"${TEST_TMPDIR}"'/bin/docker" "${HOMEBREW_PREFIX}/bin/docker"'
    assert_success
    assert_output --partial "apt-get not found; skipping Docker install"
}

@test "docker.sh skips when apt-get is absent and docker is missing" {
    # Use a PATH with no apt-get and no docker
    mkdir -p "${TEST_TMPDIR}/bin"
    ln -sf "$(command -v bash)" "${TEST_TMPDIR}/bin/bash"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"

        if command -v docker >/dev/null 2>&1; then
            echo "SKIPPED_DOCKER_EXISTS"
            exit 0
        fi
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "SKIPPED_NO_APT"
            exit 0
        fi
        echo "WOULD_INSTALL"
    '
    assert_success
    assert_output "SKIPPED_NO_APT"
}

# ---------------------------------------------------------------------------
# linux/pihole.sh — Unbound and Pi-hole against a scratch root
# ---------------------------------------------------------------------------

# A scratch root for pihole.sh (PIHOLE_ROOT) with the system commands mocked
# in ROOT/bin, each logging its call to ROOT/log: apt-get installs unbound
# by creating usr/sbin/unbound, curl hands back a fake Pi-hole installer that
# creates pihole-FTL and pihole, systemctl reports unbound-resolvconf enabled
# while ROOT/resolvconf-enabled exists, unbound-checkconf fails while
# ROOT/badconf exists, and pihole-FTL --config answers from ROOT/ftl-KEY
# (the installer sets ROOT/ftl-pwhash, as the real one sets a web password).
_make_pihole_root() {
    PIHOLE_SCRATCH="${TEST_TMPDIR}/root"
    local root="${PIHOLE_SCRATCH}"
    mkdir -p "${root}/bin" "${root}/etc/unbound/unbound.conf.d"
    : > "${root}/log"
    cat > "${root}/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${PIHOLE_ROOT}/log"
if [[ "$1" == install && "${*: -1}" == unbound ]]; then
    mkdir -p "${PIHOLE_ROOT}/usr/sbin"
    printf '#!/bin/sh\n' > "${PIHOLE_ROOT}/usr/sbin/unbound"
    chmod +x "${PIHOLE_ROOT}/usr/sbin/unbound"
fi
MOCK
    cat > "${root}/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${PIHOLE_ROOT}/log"
case "$*" in
    "is-enabled unbound-resolvconf.service"|"is-active unbound-resolvconf.service")
        [[ -e "${PIHOLE_ROOT}/resolvconf-enabled" ]] ;;
    "disable --now unbound-resolvconf.service")
        rm -f "${PIHOLE_ROOT}/resolvconf-enabled" ;;
esac
MOCK
    cat > "${root}/bin/sysctl" <<'MOCK'
#!/usr/bin/env bash
printf 'sysctl %s\n' "$*" >> "${PIHOLE_ROOT}/log"
MOCK
    cat > "${root}/bin/unbound-checkconf" <<'MOCK'
#!/usr/bin/env bash
printf 'unbound-checkconf %s\n' "$*" >> "${PIHOLE_ROOT}/log"
[[ ! -e "${PIHOLE_ROOT}/badconf" ]] || { echo "fatal error: bad config" >&2; exit 1; }
echo "unbound-checkconf: no errors in /etc/unbound/unbound.conf"
MOCK
    cat > "${root}/bin/dig" <<'MOCK'
#!/usr/bin/env bash
printf 'dig %s\n' "$*" >> "${PIHOLE_ROOT}/log"
echo 203.0.113.10
MOCK
    cat > "${root}/bin/curl" <<'MOCK'
#!/usr/bin/env bash
cat <<'INSTALLER'
printf 'installer %s DEBIAN_FRONTEND=%s\n' "$*" "${DEBIAN_FRONTEND:-}" >> "${PIHOLE_ROOT}/log"
mkdir -p "${PIHOLE_ROOT}/usr/bin" "${PIHOLE_ROOT}/usr/local/bin"
printf '#!/bin/sh\n' > "${PIHOLE_ROOT}/usr/bin/pihole-FTL"
printf '#!/bin/sh\n' > "${PIHOLE_ROOT}/usr/local/bin/pihole"
chmod +x "${PIHOLE_ROOT}/usr/bin/pihole-FTL" "${PIHOLE_ROOT}/usr/local/bin/pihole"
printf '$BALLOON-SHA256$v=1$fakehash\n' > "${PIHOLE_ROOT}/ftl-pwhash"
INSTALLER
MOCK
    cat > "${root}/bin/pihole-FTL" <<'MOCK'
#!/usr/bin/env bash
printf 'pihole-FTL %s\n' "$*" >> "${PIHOLE_ROOT}/log"
if [[ "$1" == --config && $# -eq 2 ]]; then
    case "$2" in
        dns.upstreams) cat "${PIHOLE_ROOT}/ftl-upstreams" 2>/dev/null || echo '[ "127.0.0.1#5335" ]' ;;
        dns.dnssec) cat "${PIHOLE_ROOT}/ftl-dnssec" 2>/dev/null || echo false ;;
        webserver.api.pwhash) cat "${PIHOLE_ROOT}/ftl-pwhash" 2>/dev/null || echo '""' ;;
    esac
fi
MOCK
    chmod +x "${root}"/bin/*
}

# Runs pihole.sh against the scratch root; arguments are environment settings.
_run_pihole() {
    run env PATH="${PIHOLE_SCRATCH}/bin:/usr/bin:/bin" PIHOLE_ROOT="${PIHOLE_SCRATCH}" "$@" \
        bash "${PROJECT_ROOT}/scripts/bootstrap/linux/pihole.sh" < /dev/null
}

@test "pihole.sh skips a machine without apt-get" {
    run env PATH="/usr/bin:/bin" bash "${PROJECT_ROOT}/scripts/bootstrap/linux/pihole.sh" < /dev/null
    # On a Mac there is no apt-get, so the script stops before sudo.
    assert_success
    assert_output --partial "apt-get not found; skipping Pi-hole install"
}

@test "pihole.sh installs Unbound with the guide's config, disables the resolvconf hook, then installs Pi-hole pointed at it" {
    _make_pihole_root
    local root="${PIHOLE_SCRATCH}"
    # Debian's unbound package, as apt leaves it: the resolvconf hook on.
    touch "${root}/resolvconf-enabled"
    printf 'unbound_conf=/etc/unbound/unbound.conf.d/resolvconf_resolvers.conf\n' > "${root}/etc/resolvconf.conf"
    printf 'forward-zone:\n' > "${root}/etc/unbound/unbound.conf.d/resolvconf_resolvers.conf"

    _run_pihole
    assert_success
    assert_output --partial "Installing Unbound"
    assert_output --partial "Wrote ${root}/etc/unbound/unbound.conf.d/pi-hole.conf"
    assert_output --partial "Disabling unbound-resolvconf"
    assert_output --partial "Commenting out unbound_conf in ${root}/etc/resolvconf.conf"
    assert_output --partial "Removing ${root}/etc/unbound/unbound.conf.d/resolvconf_resolvers.conf"
    assert_output --partial "Wrote ${root}/etc/sysctl.d/99-unbound.conf"
    assert_output --partial "Restarting Unbound"
    assert_output --partial "Unbound resolves pi-hole.net on 127.0.0.1#5335"
    assert_output --partial "Seeding ${root}/etc/pihole/pihole.toml with upstreams 127.0.0.1#5335"
    assert_output --partial "Installing Pi-hole"
    assert_output --partial "Pi-hole installed"
    assert_output --partial "Pi-hole web password is set"
    refute_output --partial "no web password"

    # Unbound: loopback only on 5335, validating, hardened, private ranges hidden.
    run cat "${root}/etc/unbound/unbound.conf.d/pi-hole.conf"
    assert_line --regexp "^    interface: 127.0.0.1$"
    assert_line --regexp "^    port: 5335$"
    for setting in "harden-glue: yes" "harden-dnssec-stripped: yes" "hide-identity: yes" "hide-version: yes" \
        "use-caps-for-id: no" "edns-buffer-size: 1232" "so-rcvbuf: 1m" "private-address: 10.0.0.0/8"; do
        assert_line "    ${setting}"
    done
    run cat "${root}/etc/resolvconf.conf"
    assert_output "#unbound_conf=/etc/unbound/unbound.conf.d/resolvconf_resolvers.conf"
    [ ! -e "${root}/etc/unbound/unbound.conf.d/resolvconf_resolvers.conf" ]
    run cat "${root}/etc/sysctl.d/99-unbound.conf"
    assert_output "net.core.rmem_max=1048576"
    # Pi-hole: seeded for the unattended installer, upstream Unbound, DNSSEC left to it.
    run cat "${root}/etc/pihole/pihole.toml"
    assert_output '[dns]
  upstreams = ["127.0.0.1#5335"]
  dnssec = false'
    run cat "${root}/log"
    assert_line "apt-get install -y -qq unbound"
    assert_line "systemctl disable --now unbound-resolvconf.service"
    assert_line "sysctl -q -w net.core.rmem_max=1048576"
    assert_line "systemctl enable --now unbound"
    assert_line "systemctl restart unbound"
    assert_line "dig @127.0.0.1 -p 5335 pi-hole.net +short +time=5 +tries=1"
    assert_line "installer --unattended DEBIAN_FRONTEND=noninteractive"
    # The seeded settings already match, so nothing is set through pihole-FTL.
    refute_line --partial "dns.upstreams ["
    refute_line --partial "dns.dnssec false"
}

@test "pihole.sh run again changes nothing, but brings Pi-hole's upstreams and DNSSEC back in line" {
    _make_pihole_root
    local root="${PIHOLE_SCRATCH}"
    _run_pihole
    assert_success
    : > "${root}/log"
    # The web UI moved Pi-hole off Unbound and turned its own DNSSEC on.
    printf '[ "1.1.1.1" ]\n' > "${root}/ftl-upstreams"
    printf 'true\n' > "${root}/ftl-dnssec"

    # The web password was cleared since the install.
    rm "${root}/ftl-pwhash"

    _run_pihole PIHOLE_UPSTREAMS="127.0.0.1#5335 1.1.1.1"
    assert_success
    assert_output --partial "Pi-hole has no web password"
    assert_output --partial "sudo pihole setpassword"
    assert_output --partial "Unbound already installed"
    assert_output --partial "${root}/etc/unbound/unbound.conf.d/pi-hole.conf already in place"
    assert_output --partial "Pi-hole already installed, skipping (pihole -up updates it)"
    assert_output --partial 'Pointing Pi-hole at 127.0.0.1#5335 1.1.1.1 (was [ "1.1.1.1" ])'
    assert_output --partial "Turning Pi-hole's own DNSSEC off (Unbound validates)"
    refute_output --partial "Restarting Unbound"
    refute_output --partial "Installing"
    run cat "${root}/log"
    assert_line 'pihole-FTL --config dns.upstreams ["127.0.0.1#5335", "1.1.1.1"]'
    assert_line "pihole-FTL --config dns.dnssec false"
    assert_line "systemctl enable --now unbound"
    refute_line --partial "apt-get install"
    refute_line --partial "systemctl restart"
    refute_line --partial "installer"
}

@test "pihole.sh stops before Pi-hole when unbound-checkconf rejects the config" {
    _make_pihole_root
    touch "${PIHOLE_SCRATCH}/badconf"
    _run_pihole
    assert_failure
    assert_output --partial "unbound-checkconf rejects the configuration"
    refute_output --partial "Installing Pi-hole"
    [ ! -e "${PIHOLE_SCRATCH}/etc/pihole/pihole.toml" ]
}

# ---------------------------------------------------------------------------
# bootstrap.sh — the entry point for a machine without the repo
# ---------------------------------------------------------------------------

# Runs bootstrap.sh (BOOTSTRAP, a patched copy) with a git and sudo that log
# their calls; the clone creates a fake install.sh that prints its arguments.
# BOOTSTRAP_PATH replaces the PATH it runs with.
run_bootstrap() {
    local bin="${TEST_TMPDIR}/bin"
    mkdir -p "${bin}" "${TEST_TMPDIR}/home"
    cat > "${bin}/git" <<'MOCK'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${TEST_TMPDIR}/log"
[[ "$1" == clone ]] || exit 0
mkdir -p "${@: -1}/.git"
printf '#!/usr/bin/env bash\nprintf "install.sh %%s\\n" "$*"\n' > "${@: -1}/install.sh"
MOCK
    cat > "${bin}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${TEST_TMPDIR}/log"
while [[ "$1" == -* ]]; do [[ "$1" == -u ]] && shift; shift; done
"$@"
MOCK
    chmod +x "${bin}/git" "${bin}/sudo"
    : > "${TEST_TMPDIR}/log"
    run env PATH="${BOOTSTRAP_PATH:-${bin}:/usr/bin:/bin}" HOME="${TEST_TMPDIR}/home" TEST_TMPDIR="${TEST_TMPDIR}" \
        DOTFILES_REPO="file://${TEST_TMPDIR}/origin" bash "${BOOTSTRAP:-${PROJECT_ROOT}/bootstrap.sh}" "$@" < /dev/null
}

@test "bootstrap.sh clones the repo and runs install.sh with the rest of its arguments" {
    run_bootstrap --persona vps --no-install docker
    assert_success
    assert_output "install.sh --persona vps --no-install docker"
    run grep -x "git clone --quiet file://${TEST_TMPDIR}/origin ${TEST_TMPDIR}/home/.dotfiles" "${TEST_TMPDIR}/log"
    assert_success

    # A second run finds the clone and skips straight to install.sh.
    run_bootstrap
    assert_success
    assert_line "INFO Dotfiles already at ${TEST_TMPDIR}/home/.dotfiles"
    assert_line "install.sh "
    run grep -c "git clone" "${TEST_TMPDIR}/log"
    assert_output "0"
}

@test "bootstrap.sh as root needs --user and continues as that user" {
    # The root branch, with git already there and OSTYPE as on a VPS.
    sed -e 's/^if \[\[ "${EUID}" -eq 0 \]\]; then/if true; then/' -e 's/^ensure_git$/:/' \
        "${PROJECT_ROOT}/bootstrap.sh" > "${TEST_TMPDIR}/root-bootstrap.sh"
    run env PATH="/usr/bin:/bin" HOME="${TEST_TMPDIR}" OSTYPE=linux-gnu bash "${TEST_TMPDIR}/root-bootstrap.sh" --persona vps < /dev/null
    assert_failure 2
    assert_output --partial "Running as root: name the admin user with --user NAME"

    run bash "${PROJECT_ROOT}/bootstrap.sh" --user
    assert_failure 2
    assert_output --partial "--user needs a name"
}

@test "bootstrap.sh as root with --user hardens, then clones and installs as that user" {
    [[ ! -f /etc/ssh/sshd_config.d/00-harden.conf ]] || skip "this machine is already hardened"
    local bin="${TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    # alice exists; curl hands back a harden.sh that logs its arguments.
    printf '#!/bin/sh\nexit 0\n' > "${bin}/id"
    printf '#!/bin/sh\nprintf "alice:x:1000:1000::%s:/bin/bash\\n"\n' "${TEST_TMPDIR}/alice" > "${bin}/getent"
    cat > "${bin}/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${TEST_TMPDIR}/log"
printf 'printf "harden.sh %%s\\n" "$*" >> "${TEST_TMPDIR}/log"\n'
MOCK
    chmod +x "${bin}/id" "${bin}/getent" "${bin}/curl"
    sed -e 's/^if \[\[ "${EUID}" -eq 0 \]\]; then/if true; then/' -e 's/^ensure_git$/:/' \
        "${PROJECT_ROOT}/bootstrap.sh" > "${TEST_TMPDIR}/root-bootstrap.sh"
    export BOOTSTRAP="${TEST_TMPDIR}/root-bootstrap.sh" OSTYPE=linux-gnu HARDEN_ARGS="--allow 80 --allow 443"

    run_bootstrap --user alice --persona vps
    assert_success
    assert_output --partial "INFO Creating and hardening for alice"
    assert_line "install.sh --persona vps"
    run cat "${TEST_TMPDIR}/log"
    assert_output "curl -fsSL file://${TEST_TMPDIR}/origin/raw/main/scripts/bootstrap/linux/harden.sh
harden.sh --user alice --allow 80 --allow 443
sudo -u alice -H git clone --quiet file://${TEST_TMPDIR}/origin ${TEST_TMPDIR}/alice/.dotfiles
git clone --quiet file://${TEST_TMPDIR}/origin ${TEST_TMPDIR}/alice/.dotfiles
sudo -u alice -H bash ${TEST_TMPDIR}/alice/.dotfiles/install.sh --persona vps"
}

@test "bootstrap.sh installs git through apt on Linux, and needs sudo to do it" {
    # A PATH with no git: apt-get "installs" the logging git mock into it.
    local bare="${TEST_TMPDIR}/bare" tool
    mkdir -p "${bare}"
    for tool in bash env mkdir chmod cat cp; do
        ln -s "$(command -v "${tool}")" "${bare}/${tool}"
    done
    cat > "${bare}/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${TEST_TMPDIR}/log"
[[ "$1" != install ]] || cp "${TEST_TMPDIR}/bin/git" "${TEST_TMPDIR}/bare/git"
MOCK
    chmod +x "${bare}/apt-get"
    export BOOTSTRAP_PATH="${bare}" OSTYPE=linux-gnu

    # Without sudo, a user cannot install git and nothing is cloned.
    run_bootstrap --persona vps
    assert_failure 1
    assert_output --partial "ERROR sudo is required for: apt-get update -qq"
    run cat "${TEST_TMPDIR}/log"
    assert_output ""

    ln -s "${TEST_TMPDIR}/bin/sudo" "${bare}/sudo"
    run_bootstrap --persona vps
    assert_success
    assert_line "INFO Installing git"
    assert_line "install.sh --persona vps"
    run cat "${TEST_TMPDIR}/log"
    assert_output "sudo apt-get update -qq
apt-get update -qq
sudo apt-get install -y -qq git
apt-get install -y -qq git
git clone --quiet file://${TEST_TMPDIR}/origin ${TEST_TMPDIR}/home/.dotfiles"
}

@test "bootstrap.sh --help prints usage and changes nothing" {
    run_bootstrap --help
    assert_success
    assert_line "Usage: bootstrap.sh [--user NAME] [INSTALL_ARGS...]"
    run cat "${TEST_TMPDIR}/log"
    assert_output ""
    [ ! -e "${TEST_TMPDIR}/home/.dotfiles" ]
}

# ---------------------------------------------------------------------------
# linux/tailscale.sh — idempotency guard
# ---------------------------------------------------------------------------

@test "tailscale.sh skips when tailscale is on PATH, or came through Homebrew" {
    _run_vendor_script tailscale.sh 'printf "#!/bin/sh\n" > "'"${TEST_TMPDIR}"'/bin/tailscale"; chmod +x "'"${TEST_TMPDIR}"'/bin/tailscale"'
    assert_success
    assert_output --partial "Tailscale already installed, skipping"

    _run_vendor_script tailscale.sh 'mkdir -p "${HOMEBREW_PREFIX}/bin"; printf "#!/bin/sh\n" > "${HOMEBREW_PREFIX}/bin/tailscale"; chmod +x "${HOMEBREW_PREFIX}/bin/tailscale"'
    assert_success
    assert_output --partial "Tailscale already installed, skipping"
}

# ---------------------------------------------------------------------------
# linux/harden.sh — dry runs against a scratch root with mocked system tools
# ---------------------------------------------------------------------------

# Runs harden.sh with HARDEN_ROOT pointing at a scratch tree. TS_UP=1 makes
# the mocked tailscale report a connection; ROOT_KEYS=0 leaves root without
# SSH keys and ROOT_KEYS=2 gives root only a key tied to a command; SUDO_MOCK=1
# replaces sudo with one that only prints its arguments; SSH_FROM=IP makes
# this an SSH session from IP (else the console); the mocked ip routes
# 192.168.0.0/24 and fe80::/64 on eth0 unless NO_ROUTE=1; PIHOLE=1 puts a
# Pi-hole on the box (PIHOLE_DHCP=true with its DHCP on); CF_BAD=1 makes
# Cloudflare's range list garbage. Arguments go to harden.sh.
_run_harden() {
    run bash -c '
        set -euo pipefail
        export HARDEN_ROOT="'"${TEST_TMPDIR}"'/root"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        mkdir -p "${TEST_BIN}" "${HARDEN_ROOT}/etc/ssh" "${HARDEN_ROOT}/root/.ssh"
        printf "Include /etc/ssh/sshd_config.d/*.conf\n" > "${HARDEN_ROOT}/etc/ssh/sshd_config"
        if [[ "${ROOT_KEYS:-1}" -eq 1 ]]; then
            printf "ssh-ed25519 AAAA test\n" > "${HARDEN_ROOT}/root/.ssh/authorized_keys"
        elif [[ "${ROOT_KEYS:-1}" -eq 2 ]]; then
            printf "command=\"echo log in as admin\" ssh-ed25519 AAAA test\n" > "${HARDEN_ROOT}/root/.ssh/authorized_keys"
        fi
        unset SSH_CONNECTION SSH_CLIENT
        [[ -z "${SSH_FROM:-}" ]] || export SSH_CONNECTION="${SSH_FROM} 50000 10.0.0.2 22"
        if [[ "${PIHOLE:-0}" -eq 1 ]]; then
            mkdir -p "${HARDEN_ROOT}/usr/bin"
            printf "#!/usr/bin/env bash\n" > "${HARDEN_ROOT}/usr/bin/pihole-FTL"
            chmod +x "${HARDEN_ROOT}/usr/bin/pihole-FTL"
            cat > "${TEST_BIN}/pihole-FTL" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
case "$2" in
    dhcp.active) printf "%s\n" "${PIHOLE_DHCP:-false}" ;;
    *) printf "false\n" ;;
esac
MOCK
        fi
        cat > "${TEST_BIN}/getent" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
[[ "$2" == root ]] && printf "root:x:0:0::/root:/bin/bash\n" && exit 0
exit 2
MOCK
        cat > "${TEST_BIN}/tailscale" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
[[ "${TS_UP:-0}" -eq 1 ]] || exit 1
printf "100.64.0.1 box admin@ linux -\n"
MOCK
        cat > "${TEST_BIN}/curl" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
case "$*" in
    *ips-v4) if [[ "${CF_BAD:-0}" -eq 1 ]]; then printf "garbage\n"; else printf "173.245.48.0/20\n104.16.0.0/13"; fi ;;
    *ips-v6) printf "2400:cb00::/32" ;;
esac
MOCK
        cat > "${TEST_BIN}/ip" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
[[ "${NO_ROUTE:-0}" -eq 0 ]] || exit 0
case "$*" in
    "-o -4 route show default") printf "default via 192.168.0.1 dev eth0 proto dhcp src 192.168.0.101 metric 100\n" ;;
    "-o -6 route show default") printf "default via fe80::1 dev eth0 proto ra metric 1024\n" ;;
    "-o -4 route show dev eth0 scope link") printf "192.168.0.0/24 proto kernel scope link src 192.168.0.101\n" ;;
    "-o -6 route show dev eth0") printf "fe80::/64 proto kernel metric 256\ndefault via fe80::1 proto ra metric 1024\n" ;;
esac
MOCK
        cat > "${TEST_BIN}/ss" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "udp UNCONN 0 0 127.0.0.1:5335 0.0.0.0:*\n"
printf "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n"
printf "tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*\n"
printf "tcp LISTEN 0 128 [::]:8080 [::]:*\n"
printf "tcp LISTEN 0 128 100.64.0.1:9000 0.0.0.0:*\n"
MOCK
        printf "#!/usr/bin/env bash\nexit 1\n" > "${TEST_BIN}/who"
        printf "#!/usr/bin/env bash\nexit 0\n" > "${TEST_BIN}/apt-get"
        printf "#!/usr/bin/env bash\nexit 0\n" > "${TEST_BIN}/systemctl"
        printf "#!/usr/bin/env bash\nexit 1\n" > "${TEST_BIN}/sshd"
        if [[ "${SUDO_MOCK:-0}" -eq 1 ]]; then
            printf "#!/usr/bin/env bash\nprintf \"sudo %%s\\\\n\" \"\$*\"\n" > "${TEST_BIN}/sudo"
        fi
        chmod +x "${TEST_BIN}"/*
        cd "'"${PROJECT_ROOT}"'"
        ./scripts/bootstrap/linux/harden.sh '"$*"'
    '
}

@test "harden.sh defaults to the user running it and rejects root and bad ports" {
    _run_harden --dry-run
    assert_success
    assert_output --partial "AllowUsers $(id -un)"

    _run_harden --dry-run --user root
    assert_failure
    assert_output --partial "must not be root"

    _run_harden --dry-run --user admin --allow http
    assert_failure
    assert_output --partial "Not a port: http"
}

@test "harden.sh re-runs itself through sudo when not root, for the user who ran it" {
    [[ "${EUID}" -ne 0 ]] || skip "running as root"
    SUDO_MOCK=1 _run_harden --allow 443 --cloudflare --lan 8096
    assert_success
    assert_output --regexp "^sudo --preserve-env=SSH_CONNECTION,SSH_CLIENT,TS_AUTHKEY bash .*/scripts/bootstrap/linux/harden.sh --user $(id -un) --allow 443 --cloudflare --lan 8096$"
}

@test "harden.sh closes public SSH once Tailscale is connected" {
    TS_UP=1 _run_harden --dry-run --user admin --allow 443
    assert_success
    assert_output --partial "would copy root's SSH keys to ${TEST_TMPDIR}/root/home/admin/.ssh/authorized_keys"
    assert_output --partial "admin ALL=(ALL) NOPASSWD:ALL"
    assert_output --partial "PermitRootLogin no"
    assert_output --partial "PasswordAuthentication no"
    assert_output --partial "AllowUsers admin"
    assert_output --partial "would run: ufw allow in on tailscale0"
    assert_output --partial "would run: ufw allow 443/tcp"
    assert_output --partial "would run: ufw --force delete allow 22/tcp"
    assert_output --partial "Public SSH closed"
    refute_output --partial "ufw limit 22/tcp"
    [[ ! -e "${TEST_TMPDIR}/root/etc/ssh/sshd_config.d/00-harden.conf" ]]
    [[ ! -e "${TEST_TMPDIR}/root/home/admin" ]]
}

@test "harden.sh keeps public SSH while Tailscale is not connected, and does not wait for a login without a terminal" {
    TS_UP=0 _run_harden --dry-run --user admin
    assert_success
    assert_output --partial "No terminal to log Tailscale in from"
    refute_output --partial "would run: tailscale up"
    assert_output --partial "public SSH stays open"
    assert_output --partial "would run: ufw limit 22/tcp"
    refute_output --partial "Public SSH closed"
}

@test "harden.sh opens --allow ports only to Cloudflare with --cloudflare" {
    TS_UP=1 _run_harden --dry-run --user admin --allow 443 --cloudflare
    assert_success
    assert_output --partial "would run: ufw allow proto tcp from 173.245.48.0/20 to any port 443"
    assert_output --partial "would run: ufw allow proto tcp from 104.16.0.0/13 to any port 443"
    assert_output --partial "would run: ufw allow proto tcp from 2400:cb00::/32 to any port 443"
    refute_output --partial "would run: ufw allow 443/tcp"
}

@test "harden.sh stops before any change when there is no key to copy, counting none tied to a command" {
    ROOT_KEYS=0 TS_UP=1 _run_harden --dry-run --user admin
    assert_failure
    assert_output --partial "No SSH keys for admin"
    refute_output --partial "would run: env"
    refute_output --partial "useradd"
    refute_output --partial "PermitRootLogin"
    refute_output --partial "would run: ufw"

    ROOT_KEYS=2 TS_UP=1 _run_harden --dry-run --user admin
    assert_failure
    assert_output --partial "No SSH keys for admin"
    assert_output --partial "keys tied to a command= do not count"
    refute_output --partial "would run: env"
}

@test "harden.sh stops before any change when Cloudflare's range list is not CIDRs" {
    CF_BAD=1 TS_UP=1 _run_harden --dry-run --user admin --allow 443 --cloudflare
    assert_failure
    assert_output --partial "not a CIDR: garbage"
    refute_output --partial "would run: env"
    refute_output --partial "would run: ufw"
}

@test "harden.sh closes public SSH from the console or over Tailscale, never from elsewhere" {
    SSH_FROM=203.0.113.9 TS_UP=1 _run_harden --dry-run --user admin
    assert_success
    assert_output --partial "This session came in from 203.0.113.9, not over Tailscale, so public SSH stays open"
    assert_output --partial "would run: ufw limit 22/tcp"
    refute_output --partial "Public SSH closed"

    SSH_FROM=100.101.102.103 TS_UP=1 _run_harden --dry-run --user admin
    assert_success
    assert_output --partial "Public SSH closed"
    refute_output --partial "not over Tailscale"
    refute_output --partial "would run: ufw limit 22/tcp"

    SSH_FROM=fd7a:115c:a1e0::1234 TS_UP=1 _run_harden --dry-run --user admin
    assert_success
    assert_output --partial "Public SSH closed"
}

@test "harden.sh opens a Pi-hole's DNS and admin page to the LAN and names what only the tailnet will reach" {
    PIHOLE=1 TS_UP=1 _run_harden --dry-run --user admin
    assert_success
    assert_output --partial "Pi-hole found: 53/tcp 53/udp 80/tcp 443/tcp stay open to the LAN"
    assert_output --partial "LAN: 192.168.0.0/24 on eth0, fe80::/64 on eth0"
    assert_output --partial "would run: ufw allow in on eth0 from 192.168.0.0/24 to any port 53 proto udp comment lan"
    assert_output --partial "would run: ufw allow in on eth0 from 192.168.0.0/24 to any port 53 proto tcp comment lan"
    assert_output --partial "would run: ufw allow in on eth0 from fe80::/64 to any port 53 proto udp comment lan"
    assert_output --partial "would run: ufw allow in on eth0 from 192.168.0.0/24 to any port 80 proto tcp comment lan"
    assert_output --partial "would run: ufw allow in on eth0 from 192.168.0.0/24 to any port 443 proto tcp comment lan"
    refute_output --partial "to any port 67 "
    refute_output --partial "would run: ufw allow 53"
    assert_output --partial "Listening, and reachable only over the tailnet once ufw is on: 8080/tcp"
    refute_output --partial "5335"
    refute_output --partial "9000"
    assert_output --partial "Open to the LAN: 53/tcp 53/udp 80/tcp 443/tcp"

    PIHOLE=1 PIHOLE_DHCP=true TS_UP=1 _run_harden --dry-run --user admin
    assert_success
    assert_output --partial "would run: ufw allow in on eth0 from 192.168.0.0/24 to any port 67 proto udp comment lan"
}

@test "harden.sh --lan opens a port to the LAN only, and stops before any change when there is no LAN" {
    TS_UP=1 _run_harden --dry-run --user admin --lan 8096 --lan 1900/udp
    assert_success
    assert_output --partial "would run: ufw allow in on eth0 from 192.168.0.0/24 to any port 8096 proto tcp comment lan"
    assert_output --partial "would run: ufw allow in on eth0 from 192.168.0.0/24 to any port 1900 proto udp comment lan"
    refute_output --partial "would run: ufw allow 8096"
    refute_output --partial "Pi-hole found"

    NO_ROUTE=1 TS_UP=1 _run_harden --dry-run --user admin --lan 8096
    assert_failure
    assert_output --partial "No default route, so there is no LAN to open 8096/tcp to; nothing changed."
    refute_output --partial "would run: env"
    refute_output --partial "would run: ufw"

    _run_harden --dry-run --user admin --lan 70000
    assert_failure
    assert_output --partial "Not a port: 70000"
}

# ---------------------------------------------------------------------------
# claude-code.sh — native installer, shared by macOS and Linux
# ---------------------------------------------------------------------------

_run_claude_code_script() {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/home"
        export HOMEBREW_PREFIX="'"${TEST_TMPDIR}"'/brew"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export TEST_LOG="'"${TEST_TMPDIR}"'/claude.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        mkdir -p "${HOME}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        cat > "${TEST_BIN}/curl" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "curl %s\n" "$*" >> "${TEST_LOG}"
printf "echo installer-ran >> \"\${TEST_LOG}\"\n"
MOCK
        chmod +x "${TEST_BIN}/curl"

        '"$1"'

        cd "'"${PROJECT_ROOT}"'"
        ./scripts/bootstrap/claude-code.sh
        cat "${TEST_LOG}"
    '
}

@test "claude-code.sh runs the native installer when claude is missing" {
    _run_claude_code_script ":"
    assert_success
    assert_output --partial "Installing Claude Code..."
    assert_output --partial "curl -fsSL https://claude.ai/install.sh"
    assert_output --partial "installer-ran"
}

@test "claude-code.sh skips when the native build is already installed" {
    _run_claude_code_script 'mkdir -p "${HOME}/.local/bin"; printf "#!/usr/bin/env bash\n" > "${HOME}/.local/bin/claude"; chmod +x "${HOME}/.local/bin/claude"'
    assert_success
    assert_output --partial "already installed at ${TEST_TMPDIR}/home/.local/bin/claude"
    refute_output --partial "curl "
}

@test "claude-code.sh skips when Claude Code came through Homebrew" {
    _run_claude_code_script 'mkdir -p "${HOMEBREW_PREFIX}/bin"; printf "#!/usr/bin/env bash\n" > "${HOMEBREW_PREFIX}/bin/claude"; chmod +x "${HOMEBREW_PREFIX}/bin/claude"'
    assert_success
    assert_output --partial "already installed outside ${TEST_TMPDIR}/home/.local/bin/claude"
    refute_output --partial "curl "
}

@test "claude-code.sh warns when the Homebrew cask is still installed" {
    _run_claude_code_script 'mkdir -p "${HOME}/.local/bin"; printf "#!/usr/bin/env bash\n" > "${HOME}/.local/bin/claude"; chmod +x "${HOME}/.local/bin/claude"; printf "#!/usr/bin/env bash\n[[ \"\$*\" == \"list --cask claude-code@latest\" ]]\n" > "${TEST_BIN}/brew"; chmod +x "${TEST_BIN}/brew"'
    assert_success
    assert_output --partial "Homebrew's claude-code@latest cask is still installed"
    assert_output --partial "brew uninstall --cask claude-code@latest"
}

# ---------------------------------------------------------------------------
# macos/holeberry.sh — the Holeberry role, from its release DMG
# ---------------------------------------------------------------------------

# Mocked curl, hdiutil, codesign, spctl, and ditto for holeberry.sh, each
# logging to ${TEST_TMPDIR}/holeberry.log. HB_TEAM sets the signing team,
# HB_SPCTL_RC Gatekeeper's answer, and HB_NO_DMG drops the DMG from the
# release.
_make_holeberry_mocks() {
    local bin="${TEST_TMPDIR}/bin"
    mkdir -p "${bin}" "${TEST_TMPDIR}/home" "${TEST_TMPDIR}/tmp"
    : > "${TEST_TMPDIR}/holeberry.log"

    cat > "${bin}/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${HB_LOG}"
if [[ "$*" == *api.github.com* ]]; then
    printf '{"assets": [\n'
    printf '  {"browser_download_url": "https://github.com/pedrovieira/Holeberry/releases/download/v9.9.9/appcast.xml"}'
    [[ -n "${HB_NO_DMG:-}" ]] || printf ',\n  {"browser_download_url": "https://github.com/pedrovieira/Holeberry/releases/download/v9.9.9/Holeberry-9.9.9.dmg"}'
    printf '\n]}\n'
    exit 0
fi
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then printf 'dmg\n' > "$2"; fi
    shift
done
MOCK
    cat > "${bin}/hdiutil" <<'MOCK'
#!/usr/bin/env bash
printf 'hdiutil %s\n' "$1" >> "${HB_LOG}"
if [[ "$1" == attach ]]; then
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -mountpoint ]]; then mkdir -p "$2/Holeberry.app/Contents"; fi
        shift
    done
fi
MOCK
    cat > "${bin}/codesign" <<'MOCK'
#!/usr/bin/env bash
printf 'codesign %s\n' "$1" >> "${HB_LOG}"
if [[ "$1" == -dv ]]; then printf 'TeamIdentifier=%s\n' "${HB_TEAM:-5UN5GTF749}" >&2; fi
MOCK
    cat > "${bin}/spctl" <<'MOCK'
#!/usr/bin/env bash
printf 'spctl %s\n' "$*" >> "${HB_LOG}"
exit "${HB_SPCTL_RC:-0}"
MOCK
    cat > "${bin}/ditto" <<'MOCK'
#!/usr/bin/env bash
printf 'ditto\n' >> "${HB_LOG}"
cp -R "$1" "$2"
MOCK
    chmod +x "${bin}"/*
}

# Runs holeberry.sh with the mocks; arguments are environment settings.
_run_holeberry() {
    run env "$@" HOME="${TEST_TMPDIR}/home" TMPDIR="${TEST_TMPDIR}/tmp" \
        HOLEBERRY_APPS_DIR="${TEST_TMPDIR}/Applications" \
        HB_LOG="${TEST_TMPDIR}/holeberry.log" PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" \
        bash "${PROJECT_ROOT}/scripts/bootstrap/macos/holeberry.sh" < /dev/null
}

@test "holeberry.sh installs the release's DMG once it checks the team and Gatekeeper" {
    _make_holeberry_mocks
    _run_holeberry
    assert_success
    assert_output --partial "Downloading Holeberry-9.9.9.dmg..."
    assert_output --partial "Holeberry installed at ${TEST_TMPDIR}/Applications/Holeberry.app"
    [ -d "${TEST_TMPDIR}/Applications/Holeberry.app/Contents" ]

    run cat "${TEST_TMPDIR}/holeberry.log"
    assert_line --partial "curl -fsSL -o"
    assert_line "codesign -dv"
    assert_line "codesign --verify"
    assert_line --partial "spctl --assess --type execute"
    assert_line "ditto"
    assert_line "hdiutil detach"
    # The download and its mount point are gone.
    run ls -A "${TEST_TMPDIR}/tmp"
    assert_output ""
}

@test "holeberry.sh leaves an installed copy to its own updates" {
    _make_holeberry_mocks
    mkdir -p "${TEST_TMPDIR}/Applications/Holeberry.app"
    _run_holeberry
    assert_success
    assert_output --partial "Holeberry already installed"
    run cat "${TEST_TMPDIR}/holeberry.log"
    assert_output ""
}

@test "holeberry.sh refuses an app signed by another team" {
    _make_holeberry_mocks
    _run_holeberry HB_TEAM=ABCDE12345
    assert_failure
    assert_output --partial "signed by team 'ABCDE12345', not 5UN5GTF749"
    [ ! -e "${TEST_TMPDIR}/Applications/Holeberry.app" ]
    run cat "${TEST_TMPDIR}/holeberry.log"
    assert_line "hdiutil detach"
    refute_line "ditto"
}

@test "holeberry.sh refuses an app Gatekeeper rejects" {
    _make_holeberry_mocks
    _run_holeberry HB_SPCTL_RC=3
    assert_failure
    assert_output --partial "Gatekeeper rejects Holeberry.app"
    [ ! -e "${TEST_TMPDIR}/Applications/Holeberry.app" ]
}

@test "holeberry.sh fails clearly when the release has no DMG" {
    _make_holeberry_mocks
    _run_holeberry HB_NO_DMG=1
    assert_failure
    assert_output --partial "No Holeberry DMG in the latest release"
    run cat "${TEST_TMPDIR}/holeberry.log"
    refute_line --partial "curl -fsSL -o"
}

# ---------------------------------------------------------------------------
# macos/setup.sh — mocked execution flow
# ---------------------------------------------------------------------------

@test "macOS setup.sh installs CLT and Rosetta when needed" {
    run bash -c '
        set -euo pipefail

        export TEST_ROOT="'"${TEST_TMPDIR}"'/macos-bootstrap"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_ROOT}/bootstrap.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export OSTYPE="darwin24"
        export ITERM_APP="${TEST_ROOT}/no-iTerm.app"

        mkdir -p "${TEST_BIN}"
        : > "${TEST_LOG}"

        # -p fails until --install has run, like the real installer finishing.
        cat > "${TEST_BIN}/xcode-select" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -p)
        grep -q "xcode-select --install" "${TEST_LOG}"
        ;;
    --install)
        printf "xcode-select %s\n" "$*" >> "${TEST_LOG}"
        ;;
esac
MOCK

        cat > "${TEST_BIN}/xcodebuild" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-license" && "${2:-}" == "check" ]]; then
    exit 0
fi

printf "xcodebuild %s\n" "$*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/uname" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "arm64\n"
MOCK

        cat > "${TEST_BIN}/pgrep" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 1
MOCK

        cat > "${TEST_BIN}/softwareupdate" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "softwareupdate %s\n" "$*" >> "${TEST_LOG}"
MOCK

        chmod +x \
            "${TEST_BIN}/xcode-select" \
            "${TEST_BIN}/xcodebuild" \
            "${TEST_BIN}/uname" \
            "${TEST_BIN}/pgrep" \
            "${TEST_BIN}/softwareupdate"

        cd "'"${PROJECT_ROOT}"'"
        # Closed stdin: the CLT wait polls xcode-select -p instead of reading a key.
        CLT_POLL_SECONDS=0 ./scripts/bootstrap/macos/setup.sh < /dev/null

        grep -qx "xcode-select --install" "${TEST_LOG}" || { echo "missing xcode-select install"; exit 1; }
        grep -qx "softwareupdate --install-rosetta --agree-to-license" "${TEST_LOG}" || {
            echo "missing rosetta install"
            exit 1
        }
    '
    assert_success
    assert_output --partial "Installing Xcode Command Line Tools"
    assert_output --partial "Xcode Command Line Tools installed"
    assert_output --partial "Installing Rosetta 2..."
    assert_output --partial "iTerm2 not installed; skipping its settings"
}

@test "macOS setup.sh gives up on the CLT wait after CLT_WAIT_SECONDS" {
    mkdir -p "${TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\n[[ "$1" != -p ]]\n' > "${TEST_TMPDIR}/bin/xcode-select"
    chmod +x "${TEST_TMPDIR}/bin/xcode-select"
    run env PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" OSTYPE=darwin24 CLT_POLL_SECONDS=0 CLT_WAIT_SECONDS=0 \
        "${PROJECT_ROOT}/scripts/bootstrap/macos/setup.sh" < /dev/null
    assert_failure
    assert_output --partial "still missing; finish the installer, then run install.sh again"
}

@test "macOS setup.sh --dry-run reports what is missing and installs nothing" {
    mkdir -p "${TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${TEST_TMPDIR}/bin/xcode-select"
    printf '#!/usr/bin/env bash\nprintf "arm64\\n"\n' > "${TEST_TMPDIR}/bin/uname"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${TEST_TMPDIR}/bin/pgrep"
    printf '#!/usr/bin/env bash\necho RAN >> "${TEST_TMPDIR}/ran"\n' > "${TEST_TMPDIR}/bin/softwareupdate"
    chmod +x "${TEST_TMPDIR}"/bin/*
    run env PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" OSTYPE=darwin24 TEST_TMPDIR="${TEST_TMPDIR}" \
        "${PROJECT_ROOT}/scripts/bootstrap/macos/setup.sh" --dry-run < /dev/null
    assert_success
    assert_output --partial "Would install the Xcode Command Line Tools"
    assert_output --partial "Would install Rosetta 2"
    [ ! -e "${TEST_TMPDIR}/ran" ]
}

# Runs iterm2.sh against a fake app and a `defaults` mock whose store is
# ${TEST_ROOT}/store/<key>; writes are logged to ${TEST_ROOT}/defaults.log.
# Dictionary adds and exports go through the real plist ${TEST_ROOT}/domain.plist.
_run_iterm2_script() {
    command -v plutil >/dev/null || skip "plutil is macOS-only"
    local root="${TEST_TMPDIR}/iterm2"
    mkdir -p "${root}/bin" "${root}/store" "${root}/iTerm.app"
    : > "${root}/defaults.log"
    cat > "${root}/bin/defaults" <<'MOCK'
#!/usr/bin/env bash
plist="${TEST_ROOT}/domain.plist"
case "$1" in
    read) cat "${TEST_ROOT}/store/$3" 2>/dev/null || exit 1 ;;
    export) [[ -f "${plist}" ]] && cat "${plist}" || exit 1 ;;
    write)
        if [[ "$4" == "-dict-add" ]]; then
            printf '%s\n' "${*:1:5}" >> "${TEST_ROOT}/defaults.log"
            [[ -f "${plist}" ]] || plutil -create xml1 "${plist}"
            plutil -extract "$3" raw "${plist}" >/dev/null 2>&1 || plutil -insert "$3" -dictionary "${plist}"
            plutil -replace "$3.$5" -xml "$6" "${plist}"
            exit 0
        fi
        printf '%s\n' "$*" >> "${TEST_ROOT}/defaults.log"
        [[ "$4" == "-bool" ]] && echo 1 > "${TEST_ROOT}/store/$3" || echo "$5" > "${TEST_ROOT}/store/$3"
        ;;
esac
MOCK
    chmod +x "${root}/bin/defaults"
    TEST_ROOT="${root}" ITERM_APP="${root}/iTerm.app" PATH="${root}/bin:/usr/bin:/bin" \
        run "${PROJECT_ROOT}/scripts/bootstrap/macos/iterm2.sh"
}

@test "iterm2.sh enables the Python API and makes the repo profile the default" {
    _run_iterm2_script
    assert_success
    local guid
    guid="$(jq -r '.Profiles[0].Guid' "${PROJECT_ROOT}/stow/desktop/Library/Application Support/iTerm2/DynamicProfiles/dotfiles.json")"
    run cat "${TEST_TMPDIR}/iterm2/defaults.log"
    assert_line "write com.googlecode.iterm2 EnableAPIServer -bool true"
    assert_line "write com.googlecode.iterm2 shortLivedSessionDuration -float 0"
    assert_line "write com.googlecode.iterm2 Default Bookmark Guid -string ${guid}"
}

@test "iterm2.sh writes nothing when the settings are already in place" {
    _run_iterm2_script
    _run_iterm2_script
    assert_success
    assert_output --partial "EnableAPIServer already set"
    run wc -l < "${TEST_TMPDIR}/iterm2/defaults.log"
    assert_output --regexp '^ *0$'
}

@test "iterm2.sh adds the Catppuccin color presets, fixes a stale one, and keeps the user's" {
    command -v plutil >/dev/null || skip "plutil is macOS-only"
    local root="${TEST_TMPDIR}/iterm2" presets="${PROJECT_ROOT}/stow/desktop/.config/iterm2"
    mkdir -p "${root}"
    plutil -create xml1 "${root}/domain.plist"
    plutil -insert "Custom Color Presets" -dictionary "${root}/domain.plist"
    plutil -insert "Custom Color Presets.Mine" -xml '<dict><key>a</key><integer>1</integer></dict>' "${root}/domain.plist"
    plutil -insert "Custom Color Presets.Catppuccin Mocha" -xml '<dict/>' "${root}/domain.plist"

    _run_iterm2_script
    assert_success
    assert_output --partial "Set iTerm2 color preset Catppuccin Mocha"

    run plutil -extract "Custom Color Presets.Mine.a" raw "${root}/domain.plist"
    assert_output "1"
    local name
    for name in Frappe Latte Macchiato Mocha; do
        [[ "$(plutil -extract "Custom Color Presets.Catppuccin ${name}" xml1 -o - "${root}/domain.plist")" == \
            "$(plutil -convert xml1 -o - "${presets}/Catppuccin ${name}.itermcolors")" ]] ||
            fail "Catppuccin ${name} differs from the repo file"
    done
}

# ---------------------------------------------------------------------------
# All shell scripts have correct shebang and strict mode
# ---------------------------------------------------------------------------

@test "all shell scripts use bash shebang" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/common.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden-test.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/holeberry.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            first_line="$(head -1 "${f}")"
            if [[ "${first_line}" != "#!/usr/bin/env bash" ]]; then
                echo "BAD SHEBANG: ${f} -> ${first_line}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

@test "all shell scripts enable strict mode (set -euo pipefail)" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/common.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden-test.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/holeberry.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            if ! grep -q "set -euo pipefail" "${f}"; then
                echo "MISSING strict mode: ${f}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

# ---------------------------------------------------------------------------
# All shell scripts source common.sh (except common.sh itself)
# ---------------------------------------------------------------------------

@test "all scripts except common.sh source common.sh" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/holeberry.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            if ! grep -q "source.*common\.sh" "${f}"; then
                echo "MISSING source common.sh: ${f}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

# ---------------------------------------------------------------------------
# BASEDIR resolution consistency
# ---------------------------------------------------------------------------

@test "scripts resolve BASEDIR relative to their location" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/holeberry.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            if ! grep -q "BASEDIR=" "${f}"; then
                echo "MISSING BASEDIR: ${f}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

# ---------------------------------------------------------------------------
