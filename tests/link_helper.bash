#!/usr/bin/env bash
# Shared by link.bats and link_ops.bats: the fixtures and runners for
# scripts/link.sh. Loaded after test_helper.

LINK="scripts/link.sh"
# The repo as link.sh names it, with every symlink in its path resolved.
# shellcheck disable=SC2034 # read by the suites that load this file
REPO_ROOT="$(cd "${PROJECT_ROOT}" && pwd -P)"

# Stands in for the private agents repo. Built once: link.sh only clones from
# it, so every test shares it; a test that commits to it copies it first
# (own_agents_fixture).
setup_file() {
    export AGENTS_FIXTURE="${BATS_FILE_TMPDIR}/agents-origin"
    mkdir -p "${AGENTS_FIXTURE}/skills/core/demo" "${AGENTS_FIXTURE}/skills/extra/other" \
        "${AGENTS_FIXTURE}/skills/vault/notes" \
        "${AGENTS_FIXTURE}/agents"
    # Every bundle a shipped persona asks for, so no run warns about one
    # missing (each warning is a gum process).
    local bundle
    for bundle in $(sed -n 's/^skills=//p' "${PROJECT_ROOT}"/personas/* | tr ' ' '\n' | sort -u); do
        mkdir -p "${AGENTS_FIXTURE}/skills/${bundle}/${bundle}-demo"
        printf 'skill\n' > "${AGENTS_FIXTURE}/skills/${bundle}/${bundle}-demo/SKILL.md"
    done
    printf 'rules\n' > "${AGENTS_FIXTURE}/AGENTS.md"
    printf 'agent\n' > "${AGENTS_FIXTURE}/agents/demo.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/core/demo/SKILL.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/extra/other/SKILL.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/vault/notes/SKILL.md"
    git -C "${AGENTS_FIXTURE}" init -q
    git -C "${AGENTS_FIXTURE}" add -A
    git -C "${AGENTS_FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m fixture

    # No gum, as on CI: a gum process per warning costs more than the run.
    PATH="$(path_without gum)"
    export PATH
    NO_STOW_PATH="$(path_without stow)"
    export NO_STOW_PATH
}

# PATH with each directory that holds NAME swapped for a directory of links
# to everything else in it.
path_without() {
    local name="$1" dir farm out="" i=0
    local -a dirs=()
    IFS=: read -r -a dirs <<< "${PATH}"
    for dir in "${dirs[@]}"; do
        if [[ -x "${dir}/${name}" ]]; then
            i=$((i + 1))
            farm="${BATS_FILE_TMPDIR}/no-${name}-${i}"
            mkdir -p "${farm}"
            ln -s "${dir}"/* "${farm}/"
            rm -f "${farm}/${name}"
            dir="${farm}"
        fi
        out="${out:+${out}:}${dir}"
    done
    printf '%s\n' "${out}"
}

# A private copy of the agents fixture for a test that changes it.
own_agents_fixture() {
    cp -R "${AGENTS_FIXTURE}" "${TEST_TMPDIR}/agents-origin"
    AGENTS_FIXTURE="${TEST_TMPDIR}/agents-origin"
    export AGENTS_REPO_URL="file://${AGENTS_FIXTURE}"
}

setup() {
    setup_tmpdir
    DEST="${TEST_TMPDIR}/home"
    mkdir -p "${DEST}"
    export AGENTS_REPO_URL="file://${AGENTS_FIXTURE}"
    export DOTFILES_OS=darwin
    # Keeps the machine's own Homebrew (and its tool skills) out of the tests.
    export HOMEBREW_PREFIX="${TEST_TMPDIR}/brew"
}

teardown() {
    teardown_tmpdir
}

run_link() {
    run bash "${PROJECT_ROOT}/${LINK}" --destination "${DEST}" "$@"
}

# A copy of the repo whose personas also hold "bare": the common layer only,
# no agents, no editors, on either OS. No real persona is that spare.
make_bare_repo() {
    BARE="${TEST_TMPDIR}/bare-repo"
    mkdir -p "${BARE}/scripts"
    cp -R "${PROJECT_ROOT}/stow" "${PROJECT_ROOT}/editors" "${PROJECT_ROOT}/seed" "${PROJECT_ROOT}/personas" "${PROJECT_ROOT}/roles" "${BARE}/"
    cp "${PROJECT_ROOT}/scripts/link.sh" "${PROJECT_ROOT}/scripts/common.sh" "${BARE}/scripts/"
    printf 'os=darwin,linux\nlayers=common\nagents=no\nagent_apps=\nskills=\neditors=no\nbrew=\nbrew_optional=\nroles=\n' > "${BARE}/personas/bare"
}

run_bare_link() {
    run bash "${BARE}/scripts/link.sh" --repo "${BARE}" --destination "${DEST}" "$@"
}

package_file() {
    printf '%s/stow/%s\n' "${PROJECT_ROOT}" "$1"
}

backup_of() {
    find "${DEST}/.local/state/dotfiles/clobbered" -path "*/$1" 2>/dev/null | head -1
}

stat_mode() {
    stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

# Every path under the destination except the agents checkout's .git: what
# git keeps there (locks, maintenance files) is git's doing, not link.sh's.
dest_paths() {
    (cd "${DEST}" && find . -name .git -prune -o -print | LC_ALL=C sort)
}

# Sets FIXTURE to a small dotfiles repo whose history held stow/common/.config/gone/rc
# and stow/linux/.config/tool/rc, and which now holds stow/common/.keep, a
# stow/extra package this platform does not use, and editors/code/settings.json.
make_fixture_repo() {
    FIXTURE="${TEST_TMPDIR}/fixture"
    mkdir -p "${FIXTURE}/stow/common/.config/gone" "${FIXTURE}/stow/linux/.config/tool" \
        "${FIXTURE}/stow/extra/.config/extra" "${FIXTURE}/editors/code"
    printf 'keep\n' > "${FIXTURE}/stow/common/.keep"
    printf 'gone\n' > "${FIXTURE}/stow/common/.config/gone/rc"
    printf 'tool\n' > "${FIXTURE}/stow/linux/.config/tool/rc"
    printf 'extra\n' > "${FIXTURE}/stow/extra/.config/extra/rc"
    printf '{}\n' > "${FIXTURE}/editors/code/settings.json"
    write_test_persona "${FIXTURE}" yes
    git -C "${FIXTURE}" init -q
    git -C "${FIXTURE}" add -A
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m one
    git -C "${FIXTURE}" rm -q -r stow/common/.config/gone stow/linux
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m two
}

run_fixture_link() {
    run bash "${PROJECT_ROOT}/${LINK}" --repo "${FIXTURE}" --destination "${DEST}" "$@"
}

# Runs link.sh with stdin on a pseudo-terminal and the answer typed there,
# since the layer prompt asks only on a terminal. Output is what the terminal
# showed, with its line endings normalized.
run_fixture_link_on_tty() {
    local answer="$1"
    shift
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"
    run python3 - "${answer}" bash "${PROJECT_ROOT}/${LINK}" --repo "${FIXTURE}" --destination "${DEST}" "$@" <<'PY'
import os, pty, sys
answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.environ["DOTFILES_PROMPT"] = "read"
    os.execvp(cmd[0], cmd)
os.write(fd, (answer + "\n").encode())
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
sys.exit(status >> 8 if os.WIFEXITED(status) else 1)
PY
}
