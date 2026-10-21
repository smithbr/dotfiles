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
# tool_installed: on PATH, in ~/.local/bin, or in Homebrew's bin
# ---------------------------------------------------------------------------

@test "tool_installed finds a tool on PATH, in ~/.local/bin, or under HOMEBREW_PREFIX, and nothing else" {
    local home="${TEST_TMPDIR}/home" brew="${TEST_TMPDIR}/brew"
    mkdir -p "${home}/.local/bin" "${brew}/bin" "${TEST_TMPDIR}/bin"
    printf '#!/bin/sh\n' > "${TEST_TMPDIR}/bin/onpath"
    printf '#!/bin/sh\n' > "${home}/.local/bin/native"
    printf '#!/bin/sh\n' > "${brew}/bin/brewed"
    printf '#!/bin/sh\n' > "${brew}/bin/unexecutable"
    chmod +x "${TEST_TMPDIR}/bin/onpath" "${home}/.local/bin/native" "${brew}/bin/brewed"
    run bash -c '
        export HOME="'"${home}"'" HOMEBREW_PREFIX="'"${brew}"'" PATH="'"${TEST_TMPDIR}"'/bin:/usr/bin:/bin"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        for name in onpath native brewed unexecutable absent; do
            tool_installed "${name}" && echo "${name}: yes" || echo "${name}: no"
        done
    '
    assert_success
    assert_line "onpath: yes"
    assert_line "native: yes"
    assert_line "brewed: yes"
    assert_line "unexecutable: no"
    assert_line "absent: no"
}

@test "tool_bin_dirs falls back to Homebrew's usual prefixes on both OSes" {
    run bash -c '
        export HOME="'"${TEST_TMPDIR}"'/home"; unset HOMEBREW_PREFIX
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        tool_bin_dirs
    '
    assert_success
    assert_output "${TEST_TMPDIR}/home/.local/bin
/opt/homebrew/bin
/usr/local/bin
/home/linuxbrew/.linuxbrew/bin"
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
    assert_output "INFO hello world"
}

@test "log_warn outputs to stderr with warning prefix when gum is absent" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_warn "caution" 2>&1
    '
    assert_success
    assert_output "WARN caution"
}

@test "log_error outputs to stderr with error prefix when gum is absent" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_error "something broke" 2>&1
    '
    assert_success
    assert_output "ERROR something broke"
}

@test "log_info colors its label in ANSI on a terminal, without gum" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        HAS_COLOR=true
        log_info "styled"
    '
    assert_success
    assert_output $'\033[1;38;5;86mINFO\033[0m styled'
}

@test "log_warn colors its label in ANSI on a terminal, without gum" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        HAS_COLOR_ERR=true
        log_warn "styled" 2>&1
    '
    assert_success
    assert_output $'\033[1;38;5;192mWARN\033[0m styled'
}

@test "log_error colors its label in ANSI on a terminal, without gum" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        HAS_COLOR_ERR=true
        log_error "styled" 2>&1
    '
    assert_success
    assert_output $'\033[1;38;5;204mERROR\033[0m styled'
}

@test "the last line of a run starts with SUCCESS, WARN, or ERROR" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        _success "Passed: 3"
        _warn "Failed: 1" 2>&1
        die "boom" 2>&1
    '
    assert_failure
    assert_output $'SUCCESS Passed: 3\nWARN Failed: 1\nERROR boom'
}

@test "the end-of-run label is bold and colored on a terminal" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        HAS_COLOR=true
        _success "Passed: 3"
    '
    assert_success
    assert_output $'\033[1;38;5;84mSUCCESS\033[0m Passed: 3'
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
    assert_output --partial "--selected.foreground=5"
}

@test "sourcing common.sh turns off gum's key help for its child prompts" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        env | grep "^GUM_.*_SHOW_HELP=" | sort
    '
    assert_success
    assert_output $'GUM_CHOOSE_SHOW_HELP=false\nGUM_CONFIRM_SHOW_HELP=false\nGUM_FILTER_SHOW_HELP=false\nGUM_INPUT_SHOW_HELP=false'
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

# Runs a bash script file with a pseudo-terminal on stdout, for the helpers
# that draw only on a terminal.
run_on_tty() {
    command -v script >/dev/null 2>&1 || skip "script(1) not available"
    if [[ "$(uname)" == Darwin ]]; then
        run script -q /dev/null bash "$1"
    else
        run script -qec "bash $1" /dev/null
    fi
}

@test "spin delegates to gum with shared padding on a terminal" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"
    cat > "${TEST_TMPDIR}/spin.sh" <<EOF
export PATH="${TEST_TMPDIR}/bin:\${PATH}"
source "${PROJECT_ROOT}/scripts/common.sh"
spin "Loading..." echo "payload"
EOF

    run_on_tty "${TEST_TMPDIR}/spin.sh"
    assert_success
    assert_output --partial "gum spin --spinner dot --show-error --title Loading... --padding=0 1 -- echo payload"
}

@test "spin logs the title and streams output when stdout is not a terminal" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    # Captured by run, so stdout is a pipe: a spinner here would leave cursor
    # escapes in a boxed or streamed step.
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Loading..." echo "payload"
    '
    assert_success
    refute_output --partial "gum spin"
    assert_output --partial "Loading..."
    assert_output --partial "payload"
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

@test "confirm is yes only for an answer starting with y" {
    run_picker y confirm "Delete it?"
    assert_success
    run_picker Yes confirm "Delete it?"
    assert_success
    run_picker n confirm "Delete it?"
    assert_failure
    run_picker "" confirm "Delete it?"
    assert_failure
}

@test "confirm asks with [y/N] on stderr and is no at end of input" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=read confirm "Delete it?" 2>&1 < /dev/null
    '
    assert_failure
    assert_output "Delete it? [y/N] "
}

@test "confirm hands the question to gum confirm in gum mode" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=gum confirm "Delete it?"
    '
    assert_success
    assert_output "gum confirm Delete it?"
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

@test "choose_one shows labels, prints values, and takes a number or a value" {
    run_picker 2 choose_one "Pick" "" $'Red\tred' $'Green (installed)\tgreen'
    assert_success
    assert_output "green"
    run_picker green choose_one "Pick" "" $'Red\tred' $'Green (installed)\tgreen'
    assert_output "green"
    run_picker "" choose_one "Pick" red $'Red\tred' $'Green (installed)\tgreen'
    assert_output "red"
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=read choose_one "Pick" red $'"'"'Red\tred'"'"' $'"'"'Green (installed)\tgreen'"'"' 2>&1 >/dev/null
    ' < /dev/null
    assert_success
    assert_output "Pick
  1) Red
  2) Green (installed)
Choice [red]: "
}

@test "choose_one hands gum the labels and values and selects the default by label" {
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
        DOTFILES_PROMPT=gum GUM_ARGS="'"${TEST_TMPDIR}"'/gum-args" choose_one "Pick" green red $'"'"'Green\tgreen'"'"' 2>/dev/null
    '
    assert_success
    assert_output "green"
    grep -Fqx -- "--label-delimiter="$'\t' "${TEST_TMPDIR}/gum-args"
    grep -Fqx -- "red"$'\t'"red" "${TEST_TMPDIR}/gum-args"
    grep -Fqx -- "Green"$'\t'"green" "${TEST_TMPDIR}/gum-args"
    grep -Fqx -- "--selected" "${TEST_TMPDIR}/gum-args"
    grep -Fqx -- "Green" "${TEST_TMPDIR}/gum-args"
}

@test "choose_many --selected marks the values, keeps them on Enter, and drops them on none" {
    run_picker "" choose_many --selected "green" "Pick" red green blue
    assert_success
    assert_output "green"
    run_picker none choose_many --selected "green" "Pick" red green blue
    assert_success
    assert_output ""
    run_picker "1 3" choose_many --selected "green" "Pick" $'Red\tred' $'Green\tgreen' $'Blue\tblue'
    assert_output "red
blue"
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=read choose_many --selected "green" "Pick" red green 2>&1 >/dev/null
    ' < /dev/null
    assert_success
    assert_output "Pick
  1) [ ] red
  2) [x] green
Numbers separated by spaces, all, none, or Enter to keep the [x] marks: "
}

@test "choose_many passes the selected labels to gum" {
    mkdir -p "${TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "${TEST_TMPDIR}/gum.args"\nprintf "green\\n"\n' > "${TEST_TMPDIR}/bin/gum"
    chmod +x "${TEST_TMPDIR}/bin/gum"
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':/usr/bin:/bin" TEST_TMPDIR="'"${TEST_TMPDIR}"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        DOTFILES_PROMPT=gum choose_many --selected "green blue" "Pick" $'"'"'Red\tred'"'"' $'"'"'Green\tgreen'"'"' $'"'"'Blue\tblue'"'"' 2>/dev/null
    ' < /dev/null
    assert_success
    assert_output "green"
    run grep -x -- "--selected=Green,Blue" "${TEST_TMPDIR}/gum.args"
    assert_success
    run grep -x -- "x toggles, ctrl+a ticks all, enter applies, esc skips" "${TEST_TMPDIR}/gum.args"
    assert_success
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

# ---------------------------------------------------------------------------
# Sourcing defaults, die, the run summary, and the styled-output switches
# ---------------------------------------------------------------------------

@test "sourcing common.sh defaults XDG_CONFIG_HOME under HOME, keeps a set one, and needs HOME" {
    run env -u XDG_CONFIG_HOME HOME="${TEST_TMPDIR}/home" bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        bash -c "printf \"%s\n\" \"\${XDG_CONFIG_HOME}\""
    '
    assert_success
    assert_output "${TEST_TMPDIR}/home/.config"

    run env HOME="${TEST_TMPDIR}/home" XDG_CONFIG_HOME="${TEST_TMPDIR}/xdg" bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        printf "%s\n" "${XDG_CONFIG_HOME}"
    '
    assert_output "${TEST_TMPDIR}/xdg"

    # Without HOME it sets nothing, so the caller's own HOME check still fires.
    run env -u XDG_CONFIG_HOME -u HOME bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        printf "[%s]\n" "${XDG_CONFIG_HOME:-}"
    '
    assert_success
    assert_output "[]"
}

@test "die prints its message on stderr and exits 1 before anything after it runs" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':/usr/bin:/bin"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        die "cannot continue" 2>"'"${TEST_TMPDIR}"'/stderr"
        echo "still running"
    '
    assert_failure 1
    assert_output ""
    run cat "${TEST_TMPDIR}/stderr"
    assert_output "ERROR cannot continue"
}

@test "die prints a bold red ERROR label on a terminal" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        HAS_COLOR_ERR=true
        die "cannot continue" 2>&1
    '
    assert_failure 1
    assert_output $'\033[1;38;5;204mERROR\033[0m cannot continue'
}

@test "row helpers use ANSI colors on a terminal, with no gum installed, and _warn goes to stderr" {
    run bash -c '
        export PATH="/usr/bin:/bin"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        HAS_COLOR=true HAS_COLOR_ERR=true
        _header "Section"
        _check "done"
        _caution "slow"
        _cross "broke"
        _warn "Careful" 2>/dev/null
        _warn "Careful on stderr" 2>&1 >/dev/null
    '
    assert_success
    assert_output $'\033[1;35mSection\033[0m\n\033[32m  ✓ done\033[0m\n\033[33m  ! slow\033[0m\n\033[31m  ✗ broke\033[0m\n\033[1;38;5;192mWARN\033[0m Careful on stderr'
}

@test "NO_COLOR turns styling off even on a terminal" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        NO_COLOR=1 detect_gum
        printf "%s %s\n" "${HAS_COLOR}" "${HAS_COLOR_ERR}"
    '
    assert_success
    assert_output "false false"
}

@test "add_result keeps results in order and counts each kind" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        add_result PASS "dns resolves"
        add_result WARN "cache cold"
        add_result PASS "dnssec validates"
        add_result FAIL "blocklist stale"
        add_result INFO "not counted"
        printf "%s|" "${SUMMARY_RESULTS[@]}"; printf "\n"
        printf "pass=%s warn=%s fail=%s\n" "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
    '
    assert_success
    assert_line --index 0 "PASS"$'\t'"dns resolves|WARN"$'\t'"cache cold|PASS"$'\t'"dnssec validates|FAIL"$'\t'"blocklist stale|INFO"$'\t'"not counted|"
    assert_line --index 1 "pass=2 warn=1 fail=1"
}

@test "add_next_step keeps each step once, in the order first given" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        add_next_step "sudo pihole setpassword"
        add_next_step "reboot"
        add_next_step "sudo pihole setpassword"
        add_next_step "sudo pihole"
        printf "%s\n" "${NEXT_STEPS[@]}"
    '
    assert_success
    assert_output "sudo pihole setpassword
reboot
sudo pihole"
}

@test "print_results and print_summary end a run with results, counts, and next steps" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        add_result PASS "dns resolves"
        add_result WARN "cache cold"
        add_next_step "ph-test --verbose"
        print_results
        print_summary
    '
    assert_success
    assert_output "
Summary
  PASS  dns resolves
  WARN  cache cold

SUCCESS Passed: 1  Warnings: 1  Failed: 0

Next steps
  - ph-test --verbose"
}

@test "print_summary fails when a result failed, and print_results is quiet with none" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        print_results
        add_result FAIL "blocklist stale"
        print_summary
    '
    assert_failure 1
    assert_output "
WARN Passed: 0  Warnings: 0  Failed: 1"
}

@test "show_help prints the markdown as is off a terminal and through gum format on one" {
    printf '#!/bin/sh\nprintf "gum %%s\\n" "$*"; cat\n' > "${TEST_TMPDIR}/bin/gum"
    chmod +x "${TEST_TMPDIR}/bin/gum"
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        printf "# tool\n" | show_help
        HAS_GUM=true
        printf "# tool\n" | show_help
    '
    assert_success
    assert_output "# tool
gum format
# tool"
}

@test "prompt_mode takes DOTFILES_PROMPT, and reads from stdin without a terminal even with gum" {
    printf '#!/bin/sh\n' > "${TEST_TMPDIR}/bin/gum"
    chmod +x "${TEST_TMPDIR}/bin/gum"
    local mode
    for mode in gum read; do
        run env DOTFILES_PROMPT="${mode}" PATH="/usr/bin:/bin" bash -c '
            source "'"${PROJECT_ROOT}"'/scripts/common.sh"
            prompt_mode
        ' < /dev/null
        assert_success
        assert_output "${mode}"
    done

    run env -u DOTFILES_PROMPT PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        prompt_mode
    ' < /dev/null
    assert_success
    assert_output "read"
}

@test "with stdout captured, styling is off even with gum, and the plain markers are used" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
printf 'gum %s\n' "$*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':/usr/bin:/bin"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        printf "HAS_GUM=%s\n" "${HAS_GUM}"
        _header "Section"
        _item "detail"
        _check "done"
        _cross "broke"
        _skip "not needed"
        _success "All good"
        _caution "slow"
        _warn "Careful" 2>/dev/null
        _warn "Careful on stderr" 2>&1 >/dev/null
    '
    assert_success
    assert_output "HAS_GUM=false
Section
  detail
  ok: done
  failed: broke
  skipped: not needed
SUCCESS All good
  warning: slow
WARN Careful on stderr"
}
