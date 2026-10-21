#!/usr/bin/env bats
# Tests for ph-backup against a scratch Pi-hole, Unbound, and Tailscale.

load test_helper

setup() {
    # Copies of the tools made by the tests find the shared helpers here.
    export DOTFILES_DIR="${PROJECT_ROOT}"
    setup_tmpdir
    export BIN_SANDBOX="${TEST_TMPDIR}/bin"
    mkdir -p "${BIN_SANDBOX}"
}

teardown() {
    teardown_tmpdir
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
# Both are written once, the mocks to $1: macOS checks a new executable on its first run.
write_ph_backup_mocks() {
    local dir="$1"
    mkdir -p "${dir}"

    cat > "${dir}/pihole-FTL" <<'MOCK'
#!/usr/bin/env bash
case "${1}" in
    --teleporter)
        [[ "${PH_BACKUP_TELEPORTER_STATUS:-0}" -eq 0 ]] || exit 1
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
        case "${3}" in
            *gravity*) printf '8843595\n' ;;
            *) printf '9\n' ;;
        esac
        ;;
esac
MOCK

    cat > "${dir}/pihole" <<'MOCK'
#!/usr/bin/env bash
[[ "${1}" == "-v" ]] && printf 'Core version is v6.1.4\n'
MOCK

    # Peer "m" carries Mullvad's shared-exit-node tag and must be filtered out.
    cat > "${dir}/tailscale" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1}" == "status" && "${2}" == "--json" ]]; then
    printf '{"Version":"1.90.2","BackendState":"Running","MagicDNSSuffix":"tail1.ts.net",'
    printf '"CurrentTailnet":{"Name":"example.com"},'
    printf '"Self":{"HostName":"pi","TailscaleIPs":["100.64.0.5"]},'
    printf '"Peer":{"a":{"HostName":"mac","Online":true},"b":{"HostName":"nas","Online":false},'
    printf '"m":{"HostName":"mullvad-lax","Online":true,"Tags":["tag:mullvad-exit-node"]}}}\n'
fi
MOCK

    cat > "${dir}/unbound-checkconf" <<'MOCK'
#!/usr/bin/env bash
case "${2}" in
    config-file) printf '%s\n' "${TEST_TMPDIR}/etc/unbound/unbound.conf" ;;
    interface) printf '127.0.0.1\n' ;;
    port) printf '5335\n' ;;
    auto-trust-anchor-file) printf '%s\n' "${TEST_TMPDIR}/var/lib/unbound/root.key" ;;
    *) exit 0 ;;
esac
MOCK

    cat > "${dir}/sqlite3" <<'MOCK'
#!/usr/bin/env bash
case "${2}" in
    *gravity*) printf '128432\n' ;;
    *) printf '7\n' ;;
esac
MOCK

    cat > "${dir}/hostname" <<'MOCK'
#!/usr/bin/env bash
printf 'pi\n'
MOCK

    cat > "${dir}/stat" <<'MOCK'
#!/usr/bin/env bash
[[ "${1}" == "-c" && "${2}" == "%s" ]] && exec /usr/bin/stat -f%z "${3}"
exec /usr/bin/stat "$@"
MOCK

    chmod +x "${dir}"/*

    awk '
        /^# Self-elevate if not root/ { skip = 1 }
        skip && /^fi$/ { skip = 0; next }
        skip { next }
        { print }
    ' "${PROJECT_ROOT}/stow/pihole.linux/.local/bin/ph-backup" > "${BATS_FILE_TMPDIR}/ph-backup"
    chmod +x "${BATS_FILE_TMPDIR}/ph-backup"
}

# Links the mocks into BIN_SANDBOX and the copy into TEST_TMPDIR, and lays out
# the Pi-hole and Unbound files. $1 is the Teleporter export's exit status.
setup_ph_backup_sandbox() {
    export PH_BACKUP_TELEPORTER_STATUS="${1:-0}"
    ln -s "${PH_BACKUP_MOCKS}"/* "${BIN_SANDBOX}/"
    ln -s "${BATS_FILE_TMPDIR}/ph-backup" "${TEST_TMPDIR}/ph-backup"

    mkdir -p "${TEST_TMPDIR}/etc/unbound/unbound.conf.d" "${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/var/lib/unbound" "${TEST_TMPDIR}/out"
    printf 'server:\n  port: 5335\n' > "${TEST_TMPDIR}/etc/unbound/unbound.conf.d/pi-hole.conf"
    printf 'gravity\n' > "${TEST_TMPDIR}/etc/pihole/gravity.db"
    # The trust anchor lives outside the config directory, as on Debian.
    printf 'anchor\n' > "${TEST_TMPDIR}/var/lib/unbound/root.key"
}

run_ph_backup_probe() {
    run env PATH="${BIN_SANDBOX}:/usr/bin:/bin" OSTYPE="linux-gnu" \
        PH_BACKUP_SBIN_PATHS="" \
        PH_BACKUP_UNBOUND_DIR="${TEST_TMPDIR}/etc/unbound" \
        PH_BACKUP_PIHOLE_DIR="${TEST_TMPDIR}/etc/pihole" \
        "${TEST_TMPDIR}/ph-backup" -o "${TEST_TMPDIR}/out"
}

# The mocks, and one run of the default sandbox shared by the tests that only
# read its output and archive; PH_BACKUP_RUN stands in for their TEST_TMPDIR.
setup_file() {
    local TEST_TMPDIR="${BATS_FILE_TMPDIR}/run" BIN_SANDBOX="${BATS_FILE_TMPDIR}/run/bin"
    export TEST_TMPDIR DOTFILES_DIR="${PROJECT_ROOT}" PH_BACKUP_MOCKS="${BATS_FILE_TMPDIR}/mocks"
    write_ph_backup_mocks "${PH_BACKUP_MOCKS}"
    mkdir -p "${BIN_SANDBOX}"
    setup_ph_backup_sandbox
    run_ph_backup_probe
    printf '%s' "${status}" > "${TEST_TMPDIR}/status"
    printf '%s' "${output}" > "${TEST_TMPDIR}/output"
    export PH_BACKUP_RUN="${TEST_TMPDIR}"
}

# Loads the shared run's status and output, and its archive into $archive.
load_ph_backup_run() {
    status="$(cat "${PH_BACKUP_RUN}/status")"
    output="$(cat "${PH_BACKUP_RUN}/output")"
    archive="$(find "${PH_BACKUP_RUN}/out" -name 'ph-backup-pi-*.tar.gz' -print -quit)"
}

@test "ph-backup archives the three backups plus a summary" {
    local archive
    load_ph_backup_run
    assert_success
    assert_output --partial "Teleporter archive captured"
    assert_output --partial "Tailscale state captured"
    assert_output --partial "SUMMARY.md written"
    assert_output --partial "Failed: 0"
    [[ -n "${archive}" ]]

    run tar -tzf "${archive}"
    assert_success
    assert_output --partial "SUMMARY.md"
    assert_output --partial "pi-hole_pi_teleporter_2026-01-01.zip"
    assert_output --partial "unbound-"
    assert_output --partial "tailscale-status-"
}

@test "ph-backup summary describes all three sources" {
    local archive
    load_ph_backup_run
    assert_success

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
    local archive
    load_ph_backup_run
    assert_success

    run tar -xzOf "${archive}" '*/SUMMARY.md'
    assert_success
    assert_output --partial "Restore map"

    # Every path inside the Teleporter zip and the Unbound tarball is listed
    # with the absolute path it belongs at.
    assert_output --partial '| `etc/pihole/pihole.toml` | `/etc/pihole/pihole.toml` |'
    assert_output --partial '| `etc/hosts` | `/etc/hosts` |'

    # Unbound paths are stored relative to / so each maps to one destination.
    local rel="${PH_BACKUP_RUN#/}"
    assert_output --partial '| `'"${rel}"'/etc/unbound/unbound.conf.d/pi-hole.conf` | `'"${PH_BACKUP_RUN}"'/etc/unbound/unbound.conf.d/pi-hole.conf` |'
    assert_output --partial '| `'"${rel}"'/var/lib/unbound/root.key` | `'"${PH_BACKUP_RUN}"'/var/lib/unbound/root.key` |'

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
    local archive inner="${TEST_TMPDIR}/inner"
    load_ph_backup_run
    assert_success
    mkdir -p "${inner}"
    tar -xzf "${archive}" -C "${inner}"

    run tar -tzf "$(find "${inner}" -name 'unbound-*.tar.gz' -print -quit)"
    assert_success
    assert_output --partial "${PH_BACKUP_RUN#/}/etc/unbound/unbound.conf.d/pi-hole.conf"
    assert_output --partial "${PH_BACKUP_RUN#/}/var/lib/unbound/root.key"
}

@test "ph-backup drops Mullvad exit nodes from the Tailscale state" {
    local archive inner="${TEST_TMPDIR}/inner" state
    load_ph_backup_run
    assert_success
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
    rm "${BIN_SANDBOX}/sqlite3"
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
