#!/usr/bin/env bats
# tests/deps.sh, which fetches the suite's own tools into a cache, driven with a
# stub curl that serves fixture tarballs, and run_tests.sh's preflight.

load test_helper

# Fixture tarballs, named as upstream names them, built once; each test gets
# its own copy, which one test trims.
setup_file() {
    local stage="${BATS_FILE_TMPDIR}/stage" fixtures="${BATS_FILE_TMPDIR}/fixtures"
    mkdir -p "${fixtures}" "${stage}/bats-core-1.14.0/bin" "${stage}/bats-core-1.14.0/lib/bats-core" \
        "${stage}/bats-support-0.3.0" "${stage}/bats-assert-2.2.4" \
        "${stage}/parallel-20260922/src" "${stage}/bash-5.3"
    printf '#!/bin/sh\necho "Bats stub"\n' > "${stage}/bats-core-1.14.0/bin/bats"
    chmod +x "${stage}/bats-core-1.14.0/bin/bats"
    printf 'bats_support_loaded=1\n' > "${stage}/bats-support-0.3.0/load.bash"
    printf 'bats_assert_loaded=1\n' > "${stage}/bats-assert-2.2.4/load.bash"
    printf '#!/bin/sh\necho "GNU parallel stub"\n' > "${stage}/parallel-20260922/src/parallel"
    printf '#!/bin/sh\nexit 0\n' > "${stage}/bash-5.3/configure"
    chmod +x "${stage}/bash-5.3/configure"
    tar -czf "${fixtures}/v1.14.0.tar.gz" -C "${stage}" bats-core-1.14.0
    tar -czf "${fixtures}/v0.3.0.tar.gz" -C "${stage}" bats-support-0.3.0
    tar -czf "${fixtures}/v2.2.4.tar.gz" -C "${stage}" bats-assert-2.2.4
    tar -cjf "${fixtures}/parallel-20260922.tar.bz2" -C "${stage}" parallel-20260922
    tar -czf "${fixtures}/bash-5.3.tar.gz" -C "${stage}" bash-5.3

    # The pins match the fixtures, not upstream.
    export DEPS_BATS_CORE_SHA256 DEPS_BATS_SUPPORT_SHA256 DEPS_BATS_ASSERT_SHA256 DEPS_PARALLEL_SHA256 DEPS_BASH_SHA256
    DEPS_BATS_CORE_SHA256="$(shasum -a 256 "${fixtures}/v1.14.0.tar.gz" | cut -d' ' -f1)"
    DEPS_BATS_SUPPORT_SHA256="$(shasum -a 256 "${fixtures}/v0.3.0.tar.gz" | cut -d' ' -f1)"
    DEPS_BATS_ASSERT_SHA256="$(shasum -a 256 "${fixtures}/v2.2.4.tar.gz" | cut -d' ' -f1)"
    DEPS_PARALLEL_SHA256="$(shasum -a 256 "${fixtures}/parallel-20260922.tar.bz2" | cut -d' ' -f1)"
    DEPS_BASH_SHA256="$(shasum -a 256 "${fixtures}/bash-5.3.tar.gz" | cut -d' ' -f1)"
}

setup() {
    setup_tmpdir
    export HOME="${TEST_TMPDIR}/home"
    export XDG_CACHE_HOME="${HOME}/.cache"
    export DOTFILES_TEST_DEPS="${TEST_TMPDIR}/deps"
    # Bats itself runs on a bash new enough; hand it to deps.sh so the bash
    # build step is never reached unless a test asks for it.
    export DOTFILES_TEST_BASH="${BASH}"
    unset DEPS_DIR DEPS_TEST_BASH DEPS_BATS BATS_LIB_PATH_SAVED
    FIXTURES="${TEST_TMPDIR}/fixtures"
    CURL_LOG="${TEST_TMPDIR}/curl.log"
    mkdir -p "${HOME}" "${TEST_TMPDIR}/bin"
    cp -R "${BATS_FILE_TMPDIR}/fixtures" "${FIXTURES}"

    # Only the stubs, plus the system tools deps.sh needs (tar, mktemp, shasum).
    export PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
    # Copies the fixture named like the URL's last path segment to -o DEST.
    cat > "${TEST_TMPDIR}/bin/curl" <<CURL
#!/bin/sh
dest=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) dest="\$2"; shift ;;
        -*) ;;
        *) url="\$1" ;;
    esac
    shift
done
printf '%s\n' "\$url" >> "${CURL_LOG}"
[ -f "${FIXTURES}/\${url##*/}" ] || exit 22
cp "${FIXTURES}/\${url##*/}" "\$dest"
CURL
    chmod +x "${TEST_TMPDIR}/bin/curl"

    # In-process, so a test can override a function; the real BATS_LIB_PATH is
    # restored because deps_ensure sets its own.
    BATS_LIB_PATH_SAVED="${BATS_LIB_PATH}"
    # shellcheck source=tests/deps.sh
    source "${PROJECT_ROOT}/tests/deps.sh"
}

teardown() {
    export BATS_LIB_PATH="${BATS_LIB_PATH_SAVED}"
    teardown_tmpdir
}

fetched_urls() {
    [[ -f "${CURL_LOG}" ]] && cat "${CURL_LOG}" || true
}

@test "deps: a fresh cache fetches the four tools and links them" {
    run deps_ensure
    assert_success
    assert_line "Installing test dependency: bats-core 1.14.0"
    assert_line "Installing test dependency: parallel 20260922"
    refute_output --partial "bash 5.3"

    assert test -x "${DOTFILES_TEST_DEPS}/bats-core-1.14.0/bin/bats"
    assert test -f "${DOTFILES_TEST_DEPS}/lib/bats-support/load.bash"
    assert test -f "${DOTFILES_TEST_DEPS}/lib/bats-assert/load.bash"
    # Only the script, not the rest of parallel's tarball.
    assert test -x "${DOTFILES_TEST_DEPS}/parallel-20260922/parallel"
    refute test -e "${DOTFILES_TEST_DEPS}/parallel-20260922/src"
    assert_equal "$(readlink "${DOTFILES_TEST_DEPS}/bin/bats")" "../bats-core-1.14.0/bin/bats"
    assert_equal "$(readlink "${DOTFILES_TEST_DEPS}/bin/parallel")" "../parallel-20260922/parallel"
    assert_equal "$("${DOTFILES_TEST_DEPS}/bin/bats")" "Bats stub"
    assert test -d "${DOTFILES_TEST_DEPS}/parallel-home"
    # No temp directories or archives left behind.
    run find "${DOTFILES_TEST_DEPS}" -maxdepth 1 -name '.tmp.*'
    assert_output ""

    run fetched_urls
    assert_line --index 0 "https://github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz"
    assert_line --index 1 "https://github.com/bats-core/bats-support/archive/refs/tags/v0.3.0.tar.gz"
    assert_line --index 2 "https://github.com/bats-core/bats-assert/archive/refs/tags/v2.2.4.tar.gz"
    assert_line --index 3 "https://ftp.gnu.org/gnu/parallel/parallel-20260922.tar.bz2"
    assert_equal "${#lines[@]}" 4
}

@test "deps: deps_ensure exports what run_tests.sh needs" {
    deps_ensure
    assert_equal "${DEPS_DIR}" "${DOTFILES_TEST_DEPS}"
    assert_equal "${DEPS_BATS}" "${DOTFILES_TEST_DEPS}/bin/bats"
    assert_equal "${BATS_LIB_PATH}" "${DOTFILES_TEST_DEPS}/lib"
    assert_equal "${PARALLEL_HOME}" "${DOTFILES_TEST_DEPS}/parallel-home"
    assert_equal "${DEPS_TEST_BASH}" "${BASH}"
}

@test "deps: a second run is silent and fetches nothing" {
    deps_ensure >/dev/null
    local before
    before="$(fetched_urls)"
    run deps_ensure
    assert_success
    assert_output ""
    assert_equal "$(fetched_urls)" "${before}"
}

@test "deps: a checksum mismatch fails naming both hashes and leaves nothing in the cache" {
    export DEPS_BATS_ASSERT_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    run deps_ensure
    assert_failure
    assert_output --partial "checksum mismatch for https://github.com/bats-core/bats-assert/archive/refs/tags/v2.2.4.tar.gz"
    assert_output --partial "expected 0000000000000000000000000000000000000000000000000000000000000000"
    assert_output --partial "got      $(shasum -a 256 "${FIXTURES}/v2.2.4.tar.gz" | cut -d' ' -f1)"
    refute test -e "${DOTFILES_TEST_DEPS}/bats-assert-2.2.4"
    refute test -e "${DOTFILES_TEST_DEPS}/lib"
    run find "${DOTFILES_TEST_DEPS}" -maxdepth 1 \( -name '.tmp.*' -o -name '*.tar.gz' \)
    assert_output ""
    # The tools before it stay installed.
    assert test -d "${DOTFILES_TEST_DEPS}/bats-support-0.3.0"
}

@test "deps: a failed download fails naming the URL and leaves nothing behind" {
    rm "${FIXTURES}/parallel-20260922.tar.bz2"
    run deps_ensure
    assert_failure
    assert_output --partial "download failed: https://ftp.gnu.org/gnu/parallel/parallel-20260922.tar.bz2"
    refute test -e "${DOTFILES_TEST_DEPS}/parallel-20260922"
    run find "${DOTFILES_TEST_DEPS}" -maxdepth 1 \( -name '.tmp.*' -o -name '*.tar.bz2' \)
    assert_output ""
}

@test "deps: leftovers of a killed run are removed first" {
    mkdir -p "${DOTFILES_TEST_DEPS}/.tmp.abc123/bin"
    run deps_ensure
    assert_success
    refute test -e "${DOTFILES_TEST_DEPS}/.tmp.abc123"
}

@test "deps: a bash new enough is used and none is fetched" {
    run deps_ensure
    assert_success
    run fetched_urls
    refute_output --partial "bash-5.3"
}

@test "deps: with no bash new enough, bash is fetched, built, and picked from the cache" {
    unset DOTFILES_TEST_BASH
    # Pretend every bash outside the cache is too old.
    deps_bash_ok() { [[ "$1" == "${DEPS_DIR}"/* && -x "$1" ]]; }
    # Stand in for the build: record the call and plant a bash.
    deps_build_bash() {
        printf '%s\n%s\n' "$1" "$2" > "${TEST_TMPDIR}/build.log"
        [[ -x "$1/configure" ]] || return 1
        mkdir -p "$2/bin"
        ln -s "${BASH}" "$2/bin/bash"
    }
    deps_ensure > "${TEST_TMPDIR}/out"
    assert test -f "${TEST_TMPDIR}/build.log"
    assert_equal "${DEPS_TEST_BASH}" "${DOTFILES_TEST_DEPS}/bash-5.3/bin/bash"
    assert test -x "${DEPS_TEST_BASH}"
    # The source tree and tarball do not stay in the cache.
    refute test -e "${DOTFILES_TEST_DEPS}/bash-5.3/src"
    run find "${DOTFILES_TEST_DEPS}" -maxdepth 1 \( -name '.tmp.*' -o -name '*.tar.gz' \)
    assert_output ""
    run fetched_urls
    assert_line "https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz"
    run cat "${TEST_TMPDIR}/out"
    assert_line --partial "bash 5.3 (built from source"
}

@test "deps: a failed bash build fails and leaves nothing in the cache" {
    unset DOTFILES_TEST_BASH
    deps_bash_ok() { [[ "$1" == "${DEPS_DIR}"/* && -x "$1" ]]; }
    deps_build_bash() { return 1; }
    run deps_ensure
    assert_failure
    refute test -e "${DOTFILES_TEST_DEPS}/bash-5.3"
    run find "${DOTFILES_TEST_DEPS}" -maxdepth 1 \( -name '.tmp.*' -o -name '*.tar.gz' \)
    assert_output ""
}

@test "deps: without uv there is no python link" {
    deps_ensure >/dev/null
    refute test -e "${DOTFILES_TEST_DEPS}/python/python3"
}

@test "deps: with uv the python link points at a managed Python 3.11+, installing one when needed" {
    local fake_python="${TEST_TMPDIR}/managed/python3.13"
    mkdir -p "${fake_python%/*}"
    ln -s "${BASH}" "${fake_python}"
    # uv: `python find` fails until `python install` has been asked for.
    cat > "${TEST_TMPDIR}/bin/uv" <<UV
#!/bin/sh
printf '%s\n' "\$*" >> "${TEST_TMPDIR}/uv.log"
case "\$1 \$2" in
    "python find") [ -f "${TEST_TMPDIR}/installed" ] || exit 2; printf '%s\n' "${fake_python}" ;;
    "python install") touch "${TEST_TMPDIR}/installed" ;;
esac
UV
    chmod +x "${TEST_TMPDIR}/bin/uv"

    run deps_ensure
    assert_success
    assert_line "Installing test dependency: python 3.13 (through uv)"
    assert_equal "$(readlink "${DOTFILES_TEST_DEPS}/python/python3")" "${fake_python}"
    run grep -c 'python install --managed-python --no-progress -q 3.13' "${TEST_TMPDIR}/uv.log"
    assert_output "1"

    # Next run finds it and installs nothing more.
    run deps_ensure
    assert_output ""
    run grep -c 'python install' "${TEST_TMPDIR}/uv.log"
    assert_output "1"
}

@test "deps: the cache is DOTFILES_TEST_DEPS, else under XDG_CACHE_HOME, else ~/.cache" {
    run deps_dir
    assert_output "${TEST_TMPDIR}/deps"
    unset DOTFILES_TEST_DEPS
    run deps_dir
    assert_output "${XDG_CACHE_HOME}/dotfiles/tests"
    unset XDG_CACHE_HOME
    run deps_dir
    assert_output "${HOME}/.cache/dotfiles/tests"
}

@test "deps: deps_sha256 agrees with the published digest" {
    printf 'x' > "${TEST_TMPDIR}/x"
    run deps_sha256 "${TEST_TMPDIR}/x"
    assert_output "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"
}

@test "deps: a missing curl is reported before anything is written" {
    # Off PATH entirely: the system's own curl lives in /usr/bin.
    rm "${TEST_TMPDIR}/bin/curl"
    export PATH="${TEST_TMPDIR}/bin:/bin"
    run deps_ensure
    assert_failure
    assert_output --partial "curl is required"
    refute test -e "${DOTFILES_TEST_DEPS}"
}

# run_tests.sh's preflight: the machine's own tools are required, not installed,
# and --lint-only touches neither the network nor the cache.

# A copy of the runner, from the repo root, with a stub docs lint:
# lint_docs.bats covers that, and the real one takes seconds.
runner() {
    local tests="${TEST_TMPDIR}/runner/tests"
    mkdir -p "${tests}"
    cp "${PROJECT_ROOT}/tests/run_tests.sh" "${PROJECT_ROOT}/tests/deps.sh" "${tests}/"
    printf '#!/bin/sh\n' > "${tests}/lint-docs.sh"
    (cd "${PROJECT_ROOT}" && env PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" bash "${tests}/run_tests.sh" "$@")
}

@test "runner: a missing shellcheck fails with the install hint and installs nothing" {
    run runner --lint-only
    assert_failure
    assert_output --partial "shellcheck not found"
    assert_output --partial "brew install shellcheck"
    refute test -e "${DOTFILES_TEST_DEPS}"
    refute test -e "${CURL_LOG}"
}

@test "runner: --lint-only runs shellcheck and leaves the cache alone" {
    printf '#!/bin/sh\nprintf "%%s\\n" "$#" > "%s/shellcheck.log"\n' "${TEST_TMPDIR}" > "${TEST_TMPDIR}/bin/shellcheck"
    chmod +x "${TEST_TMPDIR}/bin/shellcheck"
    ln -s "$(command -v git)" "${TEST_TMPDIR}/bin/git"
    run runner --lint-only
    assert_success
    assert_line "Running shellcheck"
    # Every tracked shell script was handed to it.
    run cat "${TEST_TMPDIR}/shellcheck.log"
    refute_output "0"
    refute test -e "${DOTFILES_TEST_DEPS}"
    refute test -e "${CURL_LOG}"
}

@test "runner: a missing stow fails with the install hint before anything is fetched" {
    printf '#!/bin/sh\nexit 0\n' > "${TEST_TMPDIR}/bin/shellcheck"
    chmod +x "${TEST_TMPDIR}/bin/shellcheck"
    ln -s "$(command -v git)" "${TEST_TMPDIR}/bin/git"
    run runner
    assert_failure
    assert_output --partial "stow not found"
    assert_output --partial "brew install stow"
    refute test -e "${DOTFILES_TEST_DEPS}"
    refute test -e "${CURL_LOG}"
}
