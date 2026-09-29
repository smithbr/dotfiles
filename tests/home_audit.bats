#!/usr/bin/env bats
# Tests for stow/tools/.local/bin/home-audit — classification of top-level dotfiles.
# shellcheck disable=SC2088 # "~/" is literal display text in expected output

load test_helper

SCRIPT="${PROJECT_ROOT}/stow/tools/.local/bin/home-audit"

setup() {
    setup_tmpdir
    export SANDBOX_HOME="${TEST_TMPDIR}/home"
    export BIN_SANDBOX="${TEST_TMPDIR}/bin"
    export HOME_AUDIT_PROGRAMS="${TEST_TMPDIR}/programs"
    mkdir -p "${SANDBOX_HOME}" "${BIN_SANDBOX}" "${HOME_AUDIT_PROGRAMS}"
    ln -sf "$(command -v bash)" "${BIN_SANDBOX}/bash"
    ln -sf "$(command -v jq)" "${BIN_SANDBOX}/jq"

    # A minimal dotfiles repo: the real link.sh decides what is managed.
    export DOTFILES_DIR="${TEST_TMPDIR}/repo"
    mkdir -p "${DOTFILES_DIR}/scripts" "${DOTFILES_DIR}/stow/common/.partly"
    cp "${PROJECT_ROOT}/scripts/link.sh" "${PROJECT_ROOT}/scripts/common.sh" "${DOTFILES_DIR}/scripts/"
    touch "${DOTFILES_DIR}/stow/common/.managed" "${DOTFILES_DIR}/stow/common/.partly/inner.conf"
    printf '#!/usr/bin/env bash\n' > "${BIN_SANDBOX}/ownedtool"
    chmod +x "${BIN_SANDBOX}/ownedtool"

    cat > "${HOME_AUDIT_PROGRAMS}/fixtures.json" <<'JSON'
{
    "name": "movetool",
    "files": [
        { "path": "$HOME/.movetool", "movable": true,
          "help": "Export the following environment variables:\n\n```bash\nexport MOVETOOL_HOME=\"$XDG_DATA_HOME\"/movetool\n```\n" },
        { "path": "$HOME/.stuckapp", "movable": false, "help": "Currently unsupported." },
        { "path": "$HOME/.npmlike", "movable": true,
          "help": "You need to put the following into your npmrc:\n\n```dosini\nprefix=${XDG_DATA_HOME}/npm\n```\n" },
        { "path": "$HOME/.config/movetool", "movable": true, "help": "nested paths are ignored" }
    ]
}
JSON

    touch "${SANDBOX_HOME}/.DS_Store" "${SANDBOX_HOME}/.settings.json.backup" "${SANDBOX_HOME}/.managed"
    mkdir -p "${SANDBOX_HOME}/.partly" "${SANDBOX_HOME}/.movetool" "${SANDBOX_HOME}/.npmlike" "${SANDBOX_HOME}/.stuckapp" \
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
    assert_output --partial "Nothing was changed"
    assert_output --partial "scripts/file-review.sh --cleanup"
    refute_output --partial "safe to delete"
}

@test "home-audit reports skipped checks when xdg-ninja data and the dotfiles repo are unavailable" {
    run env DOTFILES_DIR="${TEST_TMPDIR}/missing-repo" HOME="${SANDBOX_HOME}" HOME_AUDIT_PROGRAMS="${TEST_TMPDIR}/missing" \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" NO_COLOR=1 "${BIN_SANDBOX}/bash" "${SCRIPT}" --all
    assert_success
    assert_output --partial "XDG checks skipped"
    assert_output --partial "dotfiles repo not found"
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

@test "home-audit replaces control characters in displayed names" {
    touch "${SANDBOX_HOME}/.evil"$'\033'"[31mred.bak" "${SANDBOX_HOME}/.tab"$'\t'"name.bak"
    run_audit
    assert_success
    [[ "${output}" != *$'\033'* ]]
    assert_output --partial '~/.evil?[31mred.bak'
    assert_output --partial '~/.tab?name.bak'
}

@test "home-audit notes when each entry last changed" {
    run_audit
    assert_success
    assert_output --regexp "~/\.zzactive +[0-9.]+[KMG] +no installed owner found, but changed today"
    assert_output --regexp "~/\.zzorphan +[0-9.]+[KMG] +no installed owner, untouched [0-9]{4,} days"
    assert_output --regexp "~/\.ownedstale +[0-9.]+[KMG] +ownedstale installed, but untouched [0-9]{4,} days"
}

@test "home-audit keeps the 1Password agent link and knows commands named unlike their folder" {
    mkdir -p "${SANDBOX_HOME}/.1password" "${SANDBOX_HOME}/.vscode-shared"
    touch "${SANDBOX_HOME}/.vscode-shared/state"
    make_stale "${SANDBOX_HOME}/.1password"
    ln -s /usr/bin/true "${BIN_SANDBOX}/code"
    run_audit --all
    assert_success
    [ "$(bucket_of .1password)" = KEEP ]
    [ "$(bucket_of .vscode-shared)" = KEEP ]
    assert_output --partial "1Password SSH agent socket link"
    assert_output --partial "in use by code; changed today"
}

@test "home-audit --tsv prints every entry for scripts" {
    run_audit --tsv
    assert_success
    assert_line --regexp "^junk"$'\t'"${SANDBOX_HOME}/\.DS_Store"$'\t'"[0-9.]+[KMG]"$'\t'"backup copy or OS litter$"
    assert_line --regexp "^leftover"$'\t'"${SANDBOX_HOME}/\.zzorphan"$'\t'
    assert_line --regexp "^review"$'\t'"${SANDBOX_HOME}/\.zzactive"$'\t'
    assert_line --regexp "^keep"$'\t'"${SANDBOX_HOME}/\.managed"$'\t'$'\t'"managed by dotfiles$"
    refute_output --partial "Home audit"
    refute_output --partial "Nothing was changed"
}

@test "home-audit still runs where xdg-ninja is not installed at all" {
    run env -u HOME_AUDIT_PROGRAMS HOME_AUDIT_PREFIXES="${TEST_TMPDIR}/no-prefix" HOME="${SANDBOX_HOME}" \
        PATH="${BIN_SANDBOX}:/usr/bin:/bin" NO_COLOR=1 "${BIN_SANDBOX}/bash" "${SCRIPT}" --all
    assert_success
    assert_output --partial "XDG checks skipped"
    [ "$(bucket_of .DS_Store)" = JUNK ]
}

@test "home-audit handles a movable entry that sets no variables" {
    run_audit --all
    assert_success
    refute_output --partial "invalid variable name"
    [ "$(bucket_of .npmlike)" = MOVE ]
}
