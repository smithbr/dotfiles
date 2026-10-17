#!/usr/bin/env bash
# The test suite's own tools, fetched into a per-user cache so nothing is
# installed through Homebrew for the tests. Sourced by run_tests.sh (deps_ensure)
# or run on its own (`bash tests/deps.sh`) to warm the cache, as CI does.
#
# Cache: ${DOTFILES_TEST_DEPS:-${XDG_CACHE_HOME:-~/.cache}/dotfiles/tests}
#   bats-core-<ver>/      Bats itself, run from the extracted tree
#   bats-support-<ver>/   } bats_load_library finds them through
#   bats-assert-<ver>/    } BATS_LIB_PATH=<cache>/lib
#   parallel-<ver>/       the one Perl script GNU parallel is (`bats --jobs`)
#   bash-<ver>/bin/bash   built from source where /bin/bash is older than 4.1
#   bin/, lib/            relative links to the versions above
#   python/python3        link to a uv-managed Python 3.11+ (tomllib) when uv
#                         is installed; without uv, tests needing it skip
#   parallel-home/        PARALLEL_HOME, so parallel writes nothing into ~
# Every download is checked against the sha256 pinned below and installed by
# renaming a finished temp directory into place, so a present <name>-<ver>/
# directory is complete and a rerun with everything present touches no network.
# Delete the cache directory to start over, or after bumping a pin.
#
# Bumping a pin: set the version and the tarball's sha256 (cross-check with the
# GNU .sig or `brew info --json=v2 NAME`). GitHub has no release assets for the
# bats projects; the tag archives below are the same URLs Homebrew pins.
#
# This file runs on /bin/bash 3.2 (run_tests.sh starts there on a Mac), so no
# bash 4 features: no associative arrays, mapfile, or ${var,,}.

: "${DEPS_BATS_CORE_VERSION:=1.14.0}"
: "${DEPS_BATS_CORE_SHA256:=bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177}"
: "${DEPS_BATS_SUPPORT_VERSION:=0.3.0}"
: "${DEPS_BATS_SUPPORT_SHA256:=7815237aafeb42ddcc1b8c698fc5808026d33317d8701d5ec2396e9634e2918f}"
: "${DEPS_BATS_ASSERT_VERSION:=2.2.4}"
: "${DEPS_BATS_ASSERT_SHA256:=e305df20c4c36cba4570e10f1cd824efb1ae71d88b5ef474550781ebee04192f}"
: "${DEPS_PARALLEL_VERSION:=20260922}"
: "${DEPS_PARALLEL_SHA256:=54837e9e8c16134a3c2e95f91c5fe2f7893d4cc89f252b26735713ceca866387}"
: "${DEPS_BASH_VERSION:=5.3}"
: "${DEPS_BASH_SHA256:=0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba}"
# The uv-managed Python installed when none 3.11 or newer is there yet.
: "${DEPS_PYTHON_VERSION:=3.13}"

deps_url_github() { # org repo version
    printf 'https://github.com/%s/%s/archive/refs/tags/v%s.tar.gz\n' "$1" "$2" "$3"
}
deps_url_gnu() { # package file
    printf 'https://ftp.gnu.org/gnu/%s/%s\n' "$1" "$2"
}

deps_dir() {
    printf '%s\n' "${DOTFILES_TEST_DEPS:-${XDG_CACHE_HOME:-${HOME}/.cache}/dotfiles/tests}"
}

deps_die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

deps_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

deps_require() { # command hint
    command -v "$1" >/dev/null 2>&1 || deps_die "$1 is required to fetch the test dependencies ($2)"
}

# Download URL to DEST and check it against SHA; a mismatch removes it.
deps_fetch() { # url sha dest
    local url="$1" sha="$2" dest="$3" actual
    if ! curl -fsSL --retry 3 -o "${dest}" "${url}"; then
        rm -f "${dest}"
        printf 'error: download failed: %s\n' "${url}" >&2
        return 1
    fi
    actual="$(deps_sha256 "${dest}")"
    if [[ "${actual}" != "${sha}" ]]; then
        rm -f "${dest}"
        printf 'error: checksum mismatch for %s\n  expected %s\n  got      %s\n' "${url}" "${sha}" "${actual}" >&2
        printf 'Either the download was tampered with or the archive was regenerated; verify the tag before changing the pin in tests/deps.sh.\n' >&2
        return 1
    fi
}

# Make a temp directory inside the cache, so the final mv is a rename.
deps_tmpdir() {
    mkdir -p "${DEPS_DIR}"
    mktemp -d "${DEPS_DIR}/.tmp.XXXXXX"
}

# Rename a finished temp directory to its final name. Another run finishing
# first is fine: its result is the same.
deps_commit() { # tmp final
    if ! mv "$1" "$2" 2>/dev/null; then
        [[ -d "$2" ]] || return 1
        rm -rf "$1"
    fi
}

# Fetch a tarball and extract it (its top-level directory stripped) into
# <cache>/<name>-<version>; a no-op when that directory exists. Extra arguments
# select members to extract, named as they are in the archive.
deps_install_tarball() { # name version url sha [member...]
    local name="$1" version="$2" url="$3" sha="$4" final tmp archive
    shift 4
    final="${DEPS_DIR}/${name}-${version}"
    [[ -d "${final}" ]] && return 0

    printf 'Installing test dependency: %s %s\n' "${name}" "${version}"
    tmp="$(deps_tmpdir)" || return 1
    archive="${tmp}.${url##*/}"
    if ! deps_fetch "${url}" "${sha}" "${archive}"; then
        rm -rf "${tmp}"
        return 1
    fi
    if ! tar -xf "${archive}" -C "${tmp}" --strip-components="${DEPS_STRIP:-1}" "$@"; then
        rm -rf "${tmp}" "${archive}"
        printf 'error: could not extract %s\n' "${archive##*/}" >&2
        return 1
    fi
    rm -f "${archive}"
    deps_commit "${tmp}" "${final}"
}

deps_link() { # target link (target relative to the link's directory)
    mkdir -p "${2%/*}"
    ln -sfn "$1" "$2"
}

# Does this bash let a failing [[ ]] trip errexit (4.1 or newer)?
deps_bash_ok() {
    [[ -x "$1" ]] && "$1" -c '(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 401 ))' 2>/dev/null
}

# Build bash from the extracted source in SRC into PREFIX/bin/bash. Only the
# bash binary: no docs, loadables, or man pages. Overridden in tests.
deps_build_bash() { # src prefix
    local src="$1" prefix="$2" jobs
    deps_require cc 'install the Xcode Command Line Tools, or build-essential'
    deps_require make 'install the Xcode Command Line Tools, or build-essential'
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    # Homebrew sets this on macOS, where the function misbehaves.
    (
        cd "${src}" \
            && bash_cv_func_strchrnul_works=no ./configure --prefix="${prefix}" >"${src}/configure.log" 2>&1 \
            && make -j"${jobs}" bash >"${src}/make.log" 2>&1
    ) || {
        printf 'error: building bash failed; see %s/configure.log and make.log\n' "${src}" >&2
        return 1
    }
    mkdir -p "${prefix}/bin"
    install -m 755 "${src}/bash" "${prefix}/bin/bash"
}

# Set DEPS_TEST_BASH to a bash Bats can run on: DOTFILES_TEST_BASH, then
# /bin/bash (Linux), then the cache, building into it as a last resort.
deps_ensure_bash() {
    local final="${DEPS_DIR}/bash-${DEPS_BASH_VERSION}" candidate tmp src
    for candidate in "${DOTFILES_TEST_BASH:-}" /bin/bash "${final}/bin/bash"; do
        if [[ -n "${candidate}" ]] && deps_bash_ok "${candidate}"; then
            DEPS_TEST_BASH="${candidate}"
            export DEPS_TEST_BASH
            return 0
        fi
    done

    printf 'Installing test dependency: bash %s (built from source, about a minute)\n' "${DEPS_BASH_VERSION}"
    tmp="$(deps_tmpdir)" || return 1
    src="${tmp}/src"
    mkdir -p "${src}"
    if ! deps_fetch "$(deps_url_gnu bash "bash-${DEPS_BASH_VERSION}.tar.gz")" "${DEPS_BASH_SHA256}" "${tmp}.tar.gz" \
        || ! tar -xf "${tmp}.tar.gz" -C "${src}" --strip-components=1 \
        || ! deps_build_bash "${src}" "${tmp}"; then
        rm -rf "${tmp}" "${tmp}.tar.gz"
        return 1
    fi
    rm -rf "${src}" "${tmp}.tar.gz"
    deps_commit "${tmp}" "${final}" || return 1
    deps_bash_ok "${final}/bin/bash" || deps_die "the built bash at ${final}/bin/bash does not run"
    DEPS_TEST_BASH="${final}/bin/bash"
    export DEPS_TEST_BASH
}

# Link <cache>/python/python3 to a uv-managed Python 3.11 or newer (tomllib),
# installing DEPS_PYTHON_VERSION through uv when there is none. Without uv the
# link is removed and the tests that need it skip.
deps_ensure_python() {
    local link="${DEPS_DIR}/python/python3" python
    if ! command -v uv >/dev/null 2>&1; then
        rm -f "${link}"
        return 0
    fi
    python="$(uv python find --managed-python --no-project '>=3.11' 2>/dev/null || true)"
    if [[ -z "${python}" ]]; then
        printf 'Installing test dependency: python %s (through uv)\n' "${DEPS_PYTHON_VERSION}"
        uv python install --managed-python --no-progress -q "${DEPS_PYTHON_VERSION}" || return 1
        python="$(uv python find --managed-python --no-project '>=3.11')" || return 1
    fi
    deps_link "${python}" "${link}"
}

deps_ensure() {
    DEPS_DIR="$(deps_dir)"
    export DEPS_DIR
    deps_require curl 'install curl'
    deps_require tar 'install tar'
    case "${OSTYPE}" in
        linux*) deps_require bzip2 "apt install bzip2; GNU tar needs it for parallel's .tar.bz2" ;;
    esac
    mkdir -p "${DEPS_DIR}"
    # Leftovers of a run that was killed mid-install.
    rm -rf "${DEPS_DIR}"/.tmp.*

    deps_install_tarball bats-core "${DEPS_BATS_CORE_VERSION}" \
        "$(deps_url_github bats-core bats-core "${DEPS_BATS_CORE_VERSION}")" "${DEPS_BATS_CORE_SHA256}" || exit 1
    deps_install_tarball bats-support "${DEPS_BATS_SUPPORT_VERSION}" \
        "$(deps_url_github bats-core bats-support "${DEPS_BATS_SUPPORT_VERSION}")" "${DEPS_BATS_SUPPORT_SHA256}" || exit 1
    deps_install_tarball bats-assert "${DEPS_BATS_ASSERT_VERSION}" \
        "$(deps_url_github bats-core bats-assert "${DEPS_BATS_ASSERT_VERSION}")" "${DEPS_BATS_ASSERT_SHA256}" || exit 1
    # Only the script itself (parallel-<ver>/src/parallel); the rest of the
    # tarball is docs and tests.
    DEPS_STRIP=2 deps_install_tarball parallel "${DEPS_PARALLEL_VERSION}" \
        "$(deps_url_gnu parallel "parallel-${DEPS_PARALLEL_VERSION}.tar.bz2")" "${DEPS_PARALLEL_SHA256}" \
        "parallel-${DEPS_PARALLEL_VERSION}/src/parallel" || exit 1

    deps_link "../bats-core-${DEPS_BATS_CORE_VERSION}/bin/bats" "${DEPS_DIR}/bin/bats"
    deps_link "../parallel-${DEPS_PARALLEL_VERSION}/parallel" "${DEPS_DIR}/bin/parallel"
    deps_link "../bats-support-${DEPS_BATS_SUPPORT_VERSION}" "${DEPS_DIR}/lib/bats-support"
    deps_link "../bats-assert-${DEPS_BATS_ASSERT_VERSION}" "${DEPS_DIR}/lib/bats-assert"
    chmod +x "${DEPS_DIR}/parallel-${DEPS_PARALLEL_VERSION}/parallel"
    # Compiles the script, so a Perl missing a module shows up here, not in Bats.
    "${DEPS_DIR}/bin/parallel" --version >/dev/null 2>&1 \
        || deps_die "GNU parallel at ${DEPS_DIR}/bin/parallel does not run; is perl installed?"
    mkdir -p "${DEPS_DIR}/parallel-home"
    PARALLEL_HOME="${DEPS_DIR}/parallel-home"
    export PARALLEL_HOME

    deps_ensure_bash || exit 1
    deps_ensure_python || exit 1

    DEPS_BATS="${DEPS_DIR}/bin/bats"
    BATS_LIB_PATH="${DEPS_DIR}/lib"
    export DEPS_BATS BATS_LIB_PATH
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    deps_ensure
fi
