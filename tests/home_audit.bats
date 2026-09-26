#!/usr/bin/env bats
# Tests for dot_local/bin/home-audit — classification of top-level dotfiles.
# shellcheck disable=SC2088 # "~/" is literal display text in expected output

load test_helper

SCRIPT="${PROJECT_ROOT}/dotfiles/dot_local/bin/executable_home-audit"

setup() {
    setup_tmpdir
    export SANDBOX_HOME="${TEST_TMPDIR}/home"
    export BIN_SANDBOX="${TEST_TMPDIR}/bin"
    export HOME_AUDIT_PROGRAMS="${TEST_TMPDIR}/programs"
    mkdir -p "${SANDBOX_HOME}" "${BIN_SANDBOX}" "${HOME_AUDIT_PROGRAMS}"
    ln -sf "$(command -v bash)" "${BIN_SANDBOX}/bash"
    ln -sf "$(command -v jq)" "${BIN_SANDBOX}/jq"

    cat > "${BIN_SANDBOX}/chezmoi" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "${SANDBOX_HOME}/.managed" "${SANDBOX_HOME}/.partly/inner.conf"
MOCK
    printf '#!/usr/bin/env bash\n' > "${BIN_SANDBOX}/ownedtool"
    chmod +x "${BIN_SANDBOX}/chezmoi" "${BIN_SANDBOX}/ownedtool"

    cat > "${HOME_AUDIT_PROGRAMS}/fixtures.json" <<'JSON'
{
    "name": "movetool",
    "files": [
        { "path": "$HOME/.movetool", "movable": true,
          "help": "Export the following environment variables:\n\n```bash\nexport MOVETOOL_HOME=\"$XDG_DATA_HOME\"/movetool\n```\n" },
        { "path": "$HOME/.stuckapp", "movable": false, "help": "Currently unsupported." },
        { "path": "$HOME/.config/movetool", "movable": true, "help": "nested paths are ignored" }
    ]
}
JSON

    touch "${SANDBOX_HOME}/.DS_Store" "${SANDBOX_HOME}/.settings.json.backup" "${SANDBOX_HOME}/.managed"
    mkdir -p "${SANDBOX_HOME}/.partly" "${SANDBOX_HOME}/.movetool" "${SANDBOX_HOME}/.stuckapp" \
        "${SANDBOX_HOME}/.ownedtool" "${SANDBOX_HOME}/.zzactive" "${SANDBOX_HOME}/.zzorphan/sub" "${SANDBOX_HOME}/.ownedstale"
    touch "${SANDBOX_HOME}/.zzorphan/sub/data" "${SANDBOX_HOME}/.ownedstale/data"
    make_stale "${SANDBOX_HOME}/.zzorphan" "${SANDBOX_HOME}/.ownedstale"
    ln -s /usr/bin/true "${BIN_SANDBOX}/ownedstale"
}

teardown() {
    teardown_tmpdir
}

make_stale() {
    local dir
    for dir in "$@"; do
        find "${dir}" -exec touch -t 202001010000 {} +
    done
}

run_audit() {
    run env -u MOVETOOL_HOME HOME="${SANDBOX_HOME}" HOME_AUDIT_PROGRAMS="${HOME_AUDIT_PROGRAMS}" \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" NO_COLOR=1 "${BIN_SANDBOX}/bash" "${SCRIPT}" "$@"
}

# Prints the bucket heading that precedes the line naming the entry.
bucket_of() {
    awk -v entry="~/$1" '/^[A-Z]+ \(/ { bucket = $1 } $1 == entry { print bucket; exit }' <<<"${output}"
}

@test "home-audit sorts entries into buckets" {
    run_audit --all
    assert_success

    [ "$(bucket_of .DS_Store)" = JUNK ]
    [ "$(bucket_of .settings.json.backup)" = JUNK ]
    [ "$(bucket_of .managed)" = KEEP ]
    [ "$(bucket_of .partly)" = KEEP ]
    [ "$(bucket_of .movetool)" = MOVE ]
    [ "$(bucket_of .stuckapp)" = KEEP ]
    [ "$(bucket_of .ownedtool)" = KEEP ]
    [ "$(bucket_of .zzactive)" = REVIEW ]
    [ "$(bucket_of .ownedstale)" = REVIEW ]
    [ "$(bucket_of .zzorphan)" = LEFTOVER ]
    # shellcheck disable=SC2016 # literal help text
    assert_output --partial 'movetool: export MOVETOOL_HOME="$XDG_DATA_HOME"/movetool'
    assert_output --partial "movetool: no XDG support"
    refute_output --partial '~/.config'
}

@test "home-audit marks XDG-capable entries leftover once the environment redirects them" {
    run env HOME="${SANDBOX_HOME}" HOME_AUDIT_PROGRAMS="${HOME_AUDIT_PROGRAMS}" MOVETOOL_HOME="${TEST_TMPDIR}/xdg/movetool" \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" NO_COLOR=1 "${BIN_SANDBOX}/bash" "${SCRIPT}"
    assert_success
    [ "$(bucket_of .movetool)" = LEFTOVER ]
    assert_output --partial "\$MOVETOOL_HOME already points to ${TEST_TMPDIR}/xdg/movetool"

    # A variable that still points into the home path is not a redirect.
    run env HOME="${SANDBOX_HOME}" HOME_AUDIT_PROGRAMS="${HOME_AUDIT_PROGRAMS}" MOVETOOL_HOME="${SANDBOX_HOME}/.movetool" \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" NO_COLOR=1 "${BIN_SANDBOX}/bash" "${SCRIPT}"
    assert_success
    [ "$(bucket_of .movetool)" = MOVE ]
}

@test "home-audit hides kept entries unless --all and honours --days" {
    run_audit
    assert_success
    refute_output --partial '~/.managed'
    assert_output --partial "kept (managed, required, in use, or not movable)"

    run_audit --days 999999
    assert_success
    [ "$(bucket_of .zzorphan)" = REVIEW ]
}

@test "home-audit does not modify the audited home" {
    local before
    before="$(cd "${SANDBOX_HOME}" && find . -print | sort)"
    run_audit --all
    assert_success
    [ "$(cd "${SANDBOX_HOME}" && find . -print | sort)" = "${before}" ]
}

@test "home-audit reports skipped checks when xdg-ninja data and chezmoi are unavailable" {
    rm "${BIN_SANDBOX}/chezmoi"
    run env HOME="${SANDBOX_HOME}" HOME_AUDIT_PROGRAMS="${TEST_TMPDIR}/missing" \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" NO_COLOR=1 "${BIN_SANDBOX}/bash" "${SCRIPT}" --all
    assert_success
    assert_output --partial "XDG checks skipped"
    assert_output --partial "chezmoi unavailable"
    [ "$(bucket_of .DS_Store)" = JUNK ]
}

@test "home-audit rejects malformed arguments" {
    run_audit --days soon
    assert_failure 2
    assert_output --partial "--days needs a number"

    run_audit --home "${TEST_TMPDIR}/nope"
    assert_failure 2

    run_audit --bogus
    assert_failure 2
    assert_output --partial "unknown argument"
}
