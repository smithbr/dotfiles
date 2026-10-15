#!/usr/bin/env bats
# Tests for scripts/bootstrap/linux/harden-test.sh — the read-only hardening
# check, run against a scratch root (HARDEN_ROOT) with mocked system tools.

load test_helper

setup() {
    setup_tmpdir
    export HARDEN_ROOT="${TEST_TMPDIR}/root"
    export TEST_BIN="${TEST_TMPDIR}/bin"
    _harden_test_box
}

teardown() {
    teardown_tmpdir
}

# A hardened box seen as root: every mock reads its answer from a file under
# HARDEN_ROOT, so a test changes the box by editing those files, or sees it
# as a plain user by removing the sshd and ufw mocks.
_harden_test_box() {
    mkdir -p "${TEST_BIN}" "${HARDEN_ROOT}/etc/ssh/sshd_config.d" "${HARDEN_ROOT}/etc/ufw" "${HARDEN_ROOT}/etc/default" \
        "${HARDEN_ROOT}/etc/sudoers.d" "${HARDEN_ROOT}/etc/apt/apt.conf.d" "${HARDEN_ROOT}/home/admin/.ssh" \
        "${HARDEN_ROOT}/usr/bin" "${HARDEN_ROOT}/var/run"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n' > "${HARDEN_ROOT}/etc/ssh/sshd_config"
    printf 'PermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers admin\nMaxAuthTries 3\nX11Forwarding no\n' \
        > "${HARDEN_ROOT}/etc/ssh/sshd_config.d/00-harden.conf"
    printf 'port 22\npermitrootlogin no\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowusers admin\nmaxauthtries 3\nx11forwarding no\n' \
        > "${HARDEN_ROOT}/sshd-T"
    cat > "${HARDEN_ROOT}/ufw-status" <<'EOF'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
Anywhere on tailscale0     ALLOW IN    Anywhere                   # tailnet
41641/udp                  ALLOW IN    Anywhere                   # tailscale direct
443/tcp                    ALLOW IN    Anywhere
Anywhere (v6) on tailscale0 ALLOW IN   Anywhere (v6)
443/tcp (v6)               ALLOW IN    Anywhere (v6)
EOF
    printf 'ENABLED=yes\n' > "${HARDEN_ROOT}/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="DROP"\n' > "${HARDEN_ROOT}/etc/default/ufw"
    printf 'admin ALL=(ALL) NOPASSWD:ALL\n' > "${HARDEN_ROOT}/etc/sudoers.d/90-admin"
    printf 'ssh-ed25519 AAAA one\nssh-ed25519 BBBB two\n' > "${HARDEN_ROOT}/home/admin/.ssh/authorized_keys"
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "${HARDEN_ROOT}/etc/apt/apt.conf.d/20auto-upgrades"
    printf '#!/bin/sh\n' > "${HARDEN_ROOT}/usr/bin/unattended-upgrade"
    chmod +x "${HARDEN_ROOT}/usr/bin/unattended-upgrade"
    touch "${HARDEN_ROOT}/ts-up"
    : > "${HARDEN_ROOT}/apt-sim"
    : > "${HARDEN_ROOT}/docker-ps"

    cat > "${TEST_BIN}/sshd" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -T && -f "${HARDEN_ROOT}/sshd-T" ]] || exit 1
cat "${HARDEN_ROOT}/sshd-T"
MOCK
    cat > "${TEST_BIN}/ufw" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "status verbose" && -f "${HARDEN_ROOT}/ufw-status" ]] || { echo "ERROR: You need to be root to run this script" >&2; exit 1; }
cat "${HARDEN_ROOT}/ufw-status"
MOCK
    cat > "${TEST_BIN}/tailscale" <<'MOCK'
#!/usr/bin/env bash
[[ -f "${HARDEN_ROOT}/ts-up" ]] || exit 1
printf '100.64.0.1\n'
MOCK
    cat > "${TEST_BIN}/docker" <<'MOCK'
#!/usr/bin/env bash
[[ -f "${HARDEN_ROOT}/docker-ps" ]] || { echo "permission denied" >&2; exit 1; }
cat "${HARDEN_ROOT}/docker-ps"
MOCK
    cat > "${TEST_BIN}/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == is-enabled ]] && { cat "${HARDEN_ROOT}/timer" 2>/dev/null || printf 'enabled\n'; }
MOCK
    cat > "${TEST_BIN}/apt-get" <<'MOCK'
#!/usr/bin/env bash
cat "${HARDEN_ROOT}/apt-sim"
MOCK
    cat > "${TEST_BIN}/getent" <<'MOCK'
#!/usr/bin/env bash
case "$2" in
    admin) printf 'admin:x:1000:1000::/home/admin:/bin/bash\n' ;;
    root) printf 'root:x:0:0::/root:/bin/bash\n' ;;
    *) exit 2 ;;
esac
MOCK
    printf '#!/usr/bin/env bash\nprintf "box\\n"\n' > "${TEST_BIN}/hostname"
    chmod +x "${TEST_BIN}"/*
}

run_harden_test() {
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HARDEN_ROOT="${HARDEN_ROOT}" \
        bash "${PROJECT_ROOT}/scripts/bootstrap/linux/harden-test.sh" "$@"
}

@test "harden-test.sh passes a hardened box seen as root and lists the open ports" {
    run_harden_test --user admin
    assert_success
    assert_line "Hardening check on box, admin user admin"
    assert_line "SSH (from sshd -T)"
    assert_line "  ok: root cannot log in over SSH"
    assert_line "  ok: password logins are off"
    assert_line "  ok: only admin may log in"
    assert_line "  ok: admin can sudo (sudoers.d)"
    assert_line "  ok: admin has 2 SSH key(s)"
    assert_line "  ok: connected as 100.64.0.1"
    assert_line "  ok: ufw is active"
    assert_line "  ok: the tailnet (tailscale0) is allowed in"
    assert_line "  ok: SSH is reachable only over the tailnet"
    assert_line "  open to the internet: 443/tcp"
    assert_line "  ok: unattended upgrades are on"
    assert_line "  ok: no package upgrades pending"
    refute_output --partial "FAIL:"
    refute_output --partial "Some checks need root"
    assert_line --regexp "^[0-9]+ passed, 0 failed, 0 warning\(s\)\.$"
}

@test "harden-test.sh fails a fresh box seen as a user, reading the config files, and says what needs root" {
    rm "${TEST_BIN}/sshd" "${TEST_BIN}/ufw" "${TEST_BIN}/tailscale" "${TEST_BIN}/docker"
    rm "${HARDEN_ROOT}/etc/ssh/sshd_config.d/00-harden.conf" "${HARDEN_ROOT}/etc/sudoers.d/90-admin" \
        "${HARDEN_ROOT}/usr/bin/unattended-upgrade" "${HARDEN_ROOT}/etc/apt/apt.conf.d/20auto-upgrades"
    : > "${HARDEN_ROOT}/home/admin/.ssh/authorized_keys"
    printf 'ENABLED=no\n' > "${HARDEN_ROOT}/etc/ufw/ufw.conf"
    printf 'DEFAULT_INPUT_POLICY="ACCEPT"\n' > "${HARDEN_ROOT}/etc/default/ufw"

    run_harden_test --user admin
    assert_failure 1
    assert_line "SSH (from the config files)"
    assert_line "  FAIL: root can log in over SSH (PermitRootLogin yes, the default)"
    assert_line "  FAIL: password logins are allowed (PasswordAuthentication yes)"
    assert_line "  warn: any user with a key can log in (no AllowUsers)"
    assert_line "  FAIL: admin cannot sudo"
    assert_line "  FAIL: admin has no SSH keys in /home/admin/.ssh/authorized_keys"
    assert_line "  FAIL: Tailscale is not installed"
    assert_line "  FAIL: ufw is not enabled (sudo ufw enable)"
    assert_line "  FAIL: incoming connections are not denied by default"
    assert_line "  skipped: the rules (tailnet in, public SSH, open ports) need root: run again with sudo"
    assert_line "  FAIL: unattended-upgrades is not installed"
    assert_line "  FAIL: unattended upgrades are off (/etc/apt/apt.conf.d/20auto-upgrades)"
    assert_line "Some checks need root: run again with sudo."
    assert_line "To harden this box: sudo bash scripts/bootstrap/linux/harden.sh (see its --help)."

    # --brief: only the failures, one per line, for install.sh.
    run_harden_test --user admin --brief
    assert_failure 1
    assert_line --index 0 "root can log in over SSH (PermitRootLogin yes, the default)"
    refute_output --partial "ok:"
    refute_output --partial "warn:"
    refute_output --partial "passed"
}

@test "harden-test.sh reads the config files the way sshd does: sshd_config.d first, first value wins" {
    rm "${TEST_BIN}/sshd"
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "${HARDEN_ROOT}/etc/ssh/sshd_config.d/50-cloud-init.conf"
    run_harden_test --user admin
    assert_success
    assert_line "  ok: root cannot log in over SSH"
    assert_line "  ok: password logins are off"

    # Renamed so cloud-init's file sorts first.
    mv "${HARDEN_ROOT}/etc/ssh/sshd_config.d/00-harden.conf" "${HARDEN_ROOT}/etc/ssh/sshd_config.d/99-harden.conf"
    run_harden_test --user admin
    assert_failure 1
    assert_line "  FAIL: root can log in over SSH (PermitRootLogin yes)"
}

@test "harden-test.sh fails when the admin user is locked out, or is root" {
    printf 'port 22\npermitrootlogin no\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowusers deploy\nmaxauthtries 6\nx11forwarding yes\n' \
        > "${HARDEN_ROOT}/sshd-T"
    run_harden_test --user admin
    assert_failure 1
    assert_line "  FAIL: AllowUsers (deploy) leaves admin out"
    assert_line "  warn: 6 auth tries per connection (harden.sh sets 3)"
    assert_line "  warn: X11 forwarding is on"

    run_harden_test --user root
    assert_failure 1
    assert_line "  FAIL: the admin user is root; run as your admin user or pass --user NAME"

    run_harden_test --user nobody-here
    assert_failure 1
    assert_line "  FAIL: no user nobody-here on this machine"
}

@test "harden-test.sh judges public SSH against Tailscale: limited is a warning, closed without Tailscale a failure" {
    printf '22/tcp                     LIMIT IN    Anywhere                   # public ssh\n' >> "${HARDEN_ROOT}/ufw-status"
    run_harden_test --user admin
    assert_success
    assert_line "  warn: SSH port 22 is open to the internet, rate limited (--keep-public-ssh)"

    sed -i.bak 's/LIMIT IN/ALLOW IN/' "${HARDEN_ROOT}/ufw-status"
    run_harden_test --user admin
    assert_failure 1
    assert_line "  FAIL: SSH port 22 is open to the internet without rate limiting"

    sed -i.bak '/public ssh/d' "${HARDEN_ROOT}/ufw-status"
    rm "${HARDEN_ROOT}/ts-up"
    run_harden_test --user admin
    assert_failure 1
    assert_line "  FAIL: Tailscale is not connected (sudo tailscale up)"
    assert_line "  FAIL: SSH is closed to the internet and Tailscale is not connected: only the console can reach this box"

    printf 'Status: inactive\n' > "${HARDEN_ROOT}/ufw-status"
    run_harden_test --user admin
    assert_failure 1
    assert_line "  FAIL: ufw is not active (sudo ufw enable)"
}

@test "harden-test.sh warns about Docker ports published around ufw, pending upgrades, and a needed reboot" {
    printf 'web 0.0.0.0:8080->80/tcp, [::]:8080->80/tcp\ndb 127.0.0.1:5432->5432/tcp\n' > "${HARDEN_ROOT}/docker-ps"
    printf 'Inst openssl [3.0.2] (3.0.3 Ubuntu:22.04/jammy-security)\nInst curl [7.81] (7.82)\n' > "${HARDEN_ROOT}/apt-sim"
    printf 'disabled\n' > "${HARDEN_ROOT}/timer"
    touch "${HARDEN_ROOT}/var/run/reboot-required"
    printf 'linux-image-generic\n' > "${HARDEN_ROOT}/var/run/reboot-required.pkgs"

    run_harden_test --user admin
    assert_success
    assert_line "  warn: Docker publishes ports to all interfaces, around ufw: web (8080); bind them to 127.0.0.1 or the tailnet IP"
    assert_line "  warn: the daily upgrade timer (apt-daily-upgrade.timer) is not enabled"
    assert_line "  warn: 2 package upgrade(s) pending (sudo apt-get upgrade)"
    assert_line "  warn: a reboot is required (linux-image-generic)"
    assert_line --regexp "^[0-9]+ passed, 0 failed, 4 warning\(s\)\.$"

    rm "${HARDEN_ROOT}/docker-ps"
    run_harden_test --user admin
    assert_line "  skipped: Docker's published ports need root or the docker group"
}

@test "harden-test.sh rejects unknown arguments and bad user names" {
    run_harden_test --nope
    assert_failure 2
    assert_output --partial "Unknown argument: --nope"

    run_harden_test --user "Bad Name"
    assert_failure 2
    assert_output --partial "Not a valid user name"
}
