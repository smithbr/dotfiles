#!/usr/bin/env bats
# Tests for scripts/common.sh — logging, output helpers, require_non_root,
# sudo_cmd, spin, and the pickers.

load test_helper

setup() {
    setup_tmpdir
    export PATH="${TEST_TMPDIR}/bin:${PATH}"
    mkdir -p "${TEST_TMPDIR}/bin"
}

teardown() {
    teardown_tmpdir
}

# ---------------------------------------------------------------------------
# _check_gum / gum detection
# ---------------------------------------------------------------------------

@test "log_info outputs to stdout with info prefix when gum is absent" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_info "hello world"
    '
    assert_success
    assert_output "info: hello world"
}

@test "log_warn outputs to stderr with warning prefix when gum is absent" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_warn "caution" 2>&1
    '
    assert_success
    assert_output "warning: caution"
}

@test "log_error outputs to stderr with error prefix when gum is absent" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_error "something broke" 2>&1
    '
    assert_success
    assert_output "error: something broke"
}

@test "log_info delegates to gum when gum is on PATH" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_info "via gum"
    '
    assert_success
    assert_output --partial "gum log --level info via gum"
}

@test "log_warn delegates to gum when gum is on PATH" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*" >&2
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_warn "warning via gum" 2>&1
    '
    assert_success
    assert_output --partial "gum log --level warn warning via gum"
}

@test "log_error delegates to gum when gum is on PATH" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*" >&2
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_error "err via gum" 2>&1
    '
    assert_success
    assert_output --partial "gum log --level error err via gum"
}

@test "gum_choose_multiselect delegates to gum choose with shared styling" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        gum_choose_multiselect "Pick packages" 4 "foo" "bar"
    '
    assert_success
    assert_output --partial "gum choose --no-limit --ordered --height=4 --header=Pick packages"
    assert_output --partial "--cursor-prefix=> "
    assert_output --partial "--selected.foreground=213"
}

# ---------------------------------------------------------------------------
# require_non_root
# EUID is readonly in bash, so we test the logic by inlining the conditional.
# ---------------------------------------------------------------------------

@test "require_non_root logic accepts non-zero EUID" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        test_euid=1000
        if [[ "${test_euid}" -eq 0 ]]; then
            log_error "Do not run this script as root."
            exit 1
        fi
        echo "OK"
    '
    assert_success
    assert_output "OK"
}

@test "require_non_root logic rejects EUID 0" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        test_euid=0
        if [[ "${test_euid}" -eq 0 ]]; then
            log_error "Do not run this script as root."
            exit 1
        fi
    ' 2>&1
    assert_failure
    assert_output --partial "Do not run this script as root"
}

# ---------------------------------------------------------------------------
# sudo_cmd
# ---------------------------------------------------------------------------

@test "sudo_cmd logic runs command directly when EUID is 0" {
    run bash -c '
        test_euid=0
        if [[ "${test_euid}" -eq 0 ]]; then
            echo "ran directly"
        fi
    '
    assert_success
    assert_output "ran directly"
}

@test "sudo_cmd logic uses sudo when EUID is non-zero" {
    cat > "${TEST_TMPDIR}/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
echo "sudo: $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/sudo"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        log_error() { printf "error: %s\n" "$*" >&2; }

        sudo_cmd() {
            local test_euid=1000
            if [[ "${test_euid}" -eq 0 ]]; then
                "$@"
            elif command -v sudo >/dev/null 2>&1; then
                sudo "$@"
            else
                log_error "sudo is required for: $*"
                exit 1
            fi
        }

        sudo_cmd echo "elevated"
    '
    assert_success
    assert_output "sudo: echo elevated"
}

@test "sudo_cmd logic fails when sudo is missing and non-root" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        log_error() { printf "error: %s\n" "$*" >&2; }

        sudo_cmd() {
            local test_euid=1000
            if [[ "${test_euid}" -eq 0 ]]; then
                "$@"
            elif command -v sudo >/dev/null 2>&1; then
                sudo "$@"
            else
                log_error "sudo is required for: $*"
                exit 1
            fi
        }

        sudo_cmd echo "nope" 2>&1
    '
    assert_failure
    assert_output --partial "sudo is required"
}

# ---------------------------------------------------------------------------
# spin
# ---------------------------------------------------------------------------

@test "spin runs command and prints title when gum is absent" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Testing..." echo "payload"
    '
    assert_success
    assert_output --partial "Testing..."
    assert_output --partial "payload"
}

@test "spin returns failure when the wrapped command fails" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Should fail..." false
    '
    assert_failure
}

@test "spin invokes function directly even when gum is present" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        my_fn() { echo "from function"; }
        spin "Running fn..." my_fn
    '
    assert_success
    assert_output --partial "from function"
}

@test "spin delegates to gum with shared padding" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Loading..." echo "payload"
    '
    assert_success
    assert_output --partial "gum spin --spinner dot --title Loading... --padding=0 1 -- echo payload"
}

@test "spin bypasses gum and streams output when VERBOSE=1" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        export VERBOSE=1
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Loading..." echo "payload"
    '
    assert_success
    refute_output --partial "gum spin"
    assert_output --partial "payload"
}

@test "spin in verbose mode surfaces the real failure output before reporting failed" {
    run bash -c '
        export VERBOSE=1
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Should fail..." bash -c "echo boom >&2; exit 1"
    ' 2>&1
    assert_failure
    assert_output --partial "boom"
    assert_output --partial "Should fail... failed"
}

# ---------------------------------------------------------------------------
# _box
# ---------------------------------------------------------------------------

run_box() {
    local columns="$1" content="$2"
    local stub_bin="${TEST_TMPDIR}/bin"
    mkdir -p "${stub_bin}"
    cat > "${stub_bin}/gum" <<'EOF'
#!/usr/bin/env bash
printf 'gum-args:'
printf ' %s' "$@"
printf '\n'
cat >/dev/null
EOF
    chmod +x "${stub_bin}/gum"

    run env PATH="${stub_bin}:${PATH}" COLUMNS="${columns}" bash -c "
        set -euo pipefail
        source '${PROJECT_ROOT}/scripts/common.sh'
        HAS_GUM=true
        _box \"\$1\"
    " bash "${content}"
}

@test "_box wraps lines wider than the terminal" {
    run_box 60 "INFO Found ${HOME}/.ssh/id_ed25519.pub with no private key on disk; assuming an external agent (e.g. 1Password) manages it, leaving it untouched"
    assert_success
    assert_output --partial "--width 58"
}

@test "_box keeps a snug box for short content" {
    run_box 60 "Done."
    assert_success
    assert_output --partial "gum-args:"
    refute_output --partial "--width"
}

# ---------------------------------------------------------------------------
# choose_one / choose_many
# ---------------------------------------------------------------------------

# Runs one picker call without gum, answering with stdin; stderr is dropped.
run_picker() {
    local answer="$1"
    shift
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=read "$@" 2>/dev/null
    ' _ "$@" <<< "${answer}"
}

@test "choose_one takes a number or an item and falls back to the default" {
    run_picker 2 choose_one "Pick" red red green blue
    assert_success
    assert_output "green"
    run_picker blue choose_one "Pick" red red green blue
    assert_output "blue"
    run_picker "" choose_one "Pick" red red green blue
    assert_output "red"
    run_picker 9 choose_one "Pick" red red green blue
    assert_output "red"
    run_picker bogus choose_one "Pick" "" red green blue
    assert_success
    assert_output ""
}

@test "choose_one lists the items and the default on stderr" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=read choose_one "Which one?" green red green 2>&1 >/dev/null
    ' < /dev/null
    assert_success
    assert_output "Which one?
  1) red
  2) green
Choice [green]: "
}

@test "choose_many takes numbers or all, and none on Enter, end of input, or a bad number" {
    run_picker "1 3" choose_many "Pick" red green blue
    assert_success
    assert_output "red
blue"
    run_picker all choose_many "Pick" red green blue
    assert_output "red
green
blue"
    run_picker "" choose_many "Pick" red green blue
    assert_failure
    assert_output ""
    run_picker "2 7" choose_many "Pick" red green blue
    assert_failure
    assert_output ""
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=read choose_many "Pick" red green 2>/dev/null
    ' < /dev/null
    assert_failure
    assert_output ""
}

@test "choose_many shows labels and prints values" {
    run_picker 2 choose_many "Pick" $'Red\tred' $'Green (installed)\tgreen'
    assert_success
    assert_output "green"
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=read choose_many "Pick" $'"'"'Red\tred'"'"' 2>&1 >/dev/null
    ' < /dev/null
    assert_output --partial "  1) Red"
    refute_output --partial "red"$'\t'
}

@test "choose_many hands gum the labels and values and passes its choices through" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == choose ]] || exit 0
printf '%s\n' "$@" > "${GUM_ARGS}"
printf 'green\n'
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':/usr/bin:/bin"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=gum GUM_ARGS="'"${TEST_TMPDIR}"'/gum-args" choose_many "Pick" red $'"'"'Green\tgreen'"'"' 2>/dev/null
    '
    assert_success
    assert_output "green"
    grep -Fqx -- "--no-limit" "${TEST_TMPDIR}/gum-args"
    grep -Fqx -- "--header=Pick" "${TEST_TMPDIR}/gum-args"
    grep -Fqx -- "red"$'\t'"red" "${TEST_TMPDIR}/gum-args"
    grep -Fqx -- "Green"$'\t'"green" "${TEST_TMPDIR}/gum-args"
}
