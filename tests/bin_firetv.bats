#!/usr/bin/env bats
# Tests for firetv against a mocked adb and ph.

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
    "shell pm list packages -3 --show-versioncode")
        printf 'package:%s\r\n' 'com.netflix.ninja versionCode:27207' 'com.amazon.tv.settings.v2.overlay.localisation.common versionCode:0' \
            $({ grep -v -E '^(com\.amazon|com\.example)' "${FIRETV_STATE}/installed" || true; } | sed 's/$/ versionCode:1/' | tr ' ' '#') | tr '#' ' ' ;;
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
    "install -r "*)
        [[ "$3" != *broken* ]] || { printf 'Failure [INSTALL_PARSE_FAILED_NOT_APK]\n'; exit 1; }
        basename "$3" .apk >> "${FIRETV_STATE}/installed"
        printf 'Performing Streamed Install\r\nSuccess\r\n' ;;
    "uninstall "*)
        grep -vxF "$2" "${FIRETV_STATE}/installed" > "${FIRETV_STATE}/i.tmp" || true
        mv "${FIRETV_STATE}/i.tmp" "${FIRETV_STATE}/installed"
        printf 'Success\r\n' ;;
    "shell df -k /data")
        printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\r\n/dev/block/dm-17 9339420 2299140 %s 26%% /data\r\n' \
            "$(cat "${FIRETV_STATE}/free" 2>/dev/null || printf 6892824)" ;;
    "shell pm trim-caches 999G") printf '%s\n' "$(( $(cat "${FIRETV_STATE}/free" 2>/dev/null || printf 6892824) + 204800 ))" > "${FIRETV_STATE}/free" ;;
    "shell dumpsys package com.amazon.venezia") printf '  Package [com.amazon.venezia]\r\n    userId=10171\r\n' ;;
    "shell dumpsys package com.amazon.device.metrics")
        printf '    userId=10194\r\n    versionCode=%s minSdk=30 targetSdk=28\r\n' "$(cat "${FIRETV_STATE}/metrics-version" 2>/dev/null || printf 1)" ;;
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
    *"/proc/net/tcp"*"-v u=10194 "*)
        [[ ! -e "${FIRETV_STATE}/metrics-connects" ]] || printf '%s\r\n' 0000000000000000FFFF0000D3B1A736:01BB ;;
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

    # The rate limit's retry backs off with sleep; skip the wait, not the retry.
    printf '#!/bin/sh\n' > "${BIN_SANDBOX}/sleep"
    chmod +x "${BIN_SANDBOX}/sleep"
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

@test "firetv apps lists installed apps without system overlays, and install sideloads an APK" {
    setup_firetv_sandbox
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" apps
    assert_success
    assert_line --regexp '^  com\.netflix\.ninja +27207$'
    refute_output --partial "overlay"

    printf 'not really an apk' > "${TEST_TMPDIR}/org.example.clock.apk"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" install "${TEST_TMPDIR}/org.example.clock.apk"
    assert_success
    assert_output --partial "Installed org.example.clock.apk"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" apps
    assert_line --regexp '^  org\.example\.clock +1$'

    printf 'x' > "${TEST_TMPDIR}/broken.apk"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" install "${TEST_TMPDIR}/broken.apk"
    assert_failure
    assert_output --partial "Install failed: Failure [INSTALL_PARSE_FAILED_NOT_APK]"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" install "${TEST_TMPDIR}/missing.apk"
    assert_failure
    assert_output --partial "No such file"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" install "${TEST_TMPDIR}/notes.txt"
    assert_failure
    assert_output --partial "Not an APK"
}

@test "firetv uninstall removes only your own apps, and only when told yes" {
    setup_firetv_sandbox
    printf '%s\n' org.example.clock >> "${FIRETV_STATE}/installed"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" uninstall org.example.clock < /dev/null
    assert_success
    assert_output --partial "org.example.clock kept"
    run grep -c ' uninstall org.example.clock$' "${FIRETV_STATE}/calls.log"
    assert_output "0"

    run bash -c 'printf "1\n" | env PATH="$1" DOTFILES_PROMPT=read "$2" uninstall org.example.clock' _ "${BIN_SANDBOX}:${PATH}" "${FIRETV}"
    assert_success
    assert_output --partial "Uninstalled org.example.clock"
    run grep -cxF org.example.clock "${FIRETV_STATE}/installed"
    assert_output "0"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" uninstall com.amazon.tv.launcher < /dev/null
    assert_failure
    assert_output --partial "core package the TV needs"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" uninstall com.amazon.tv.settings.v2.overlay.localisation.common < /dev/null
    assert_failure
    assert_output --partial "system resource overlay"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" uninstall com.amazon.tv.acr < /dev/null
    assert_failure
    assert_output --partial "built in and can't be uninstalled; firetv disable com.amazon.tv.acr"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" uninstall org.example.gone < /dev/null
    assert_failure
    assert_output --partial "org.example.gone is not on this TV"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" uninstall 'x;reboot' < /dev/null
    assert_failure
    assert_output --partial "Not a package name"
    run grep -c -E ' uninstall [^ ]+$' "${FIRETV_STATE}/calls.log"
    assert_output "1"
}

@test "firetv doctor trusts a clean watch of a needs-root package until its version changes" {
    setup_firetv_pihole
    printf '%s\n' com.amazon.device.metrics > "${FIRETV_STATE_DIR}/needs-root"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --partial "warning: com.amazon.device.metrics needs root and has no hostnames in its code; watch what it connects to"

    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --watch 1 domains com.amazon.device.metrics < /dev/null
    assert_success
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_success
    assert_output --regexp "ok: com\.amazon\.device\.metrics needs root; no hostnames in its code, no connections in a 1s watch on [0-9]{4}-[0-9]{2}-[0-9]{2}"
    refute_output --partial "domains com.amazon.device.metrics"

    printf '%s\n' 2 > "${FIRETV_STATE}/metrics-version"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_output --partial "warning: com.amazon.device.metrics needs root and changed version since the watch on"
    assert_output --partial "- firetv --watch 120 domains com.amazon.device.metrics"

    touch "${FIRETV_STATE}/metrics-connects"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" --watch 1 domains com.amazon.device.metrics < /dev/null
    assert_success
    assert_output --partial "54.167.177.211:443"
    run env PATH="${BIN_SANDBOX}:${PATH}" "${FIRETV}" doctor < /dev/null
    assert_output --partial "warning: com.amazon.device.metrics needs root and made connections in the watch on"
    run grep -c com.amazon.device.metrics "${FIRETV_STATE_DIR}/watched"
    assert_output "1"
}
