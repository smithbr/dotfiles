#!/usr/bin/env bash
# Boot a throwaway Debian container and run a full dotfiles install inside it.
#
# This is the only check that exercises install.sh against a genuinely bare
# machine: no git, no curl, no zsh, and stdin closed. The bats suite mocks all
# of that away.
#
# `docker exec` without -i leaves stdin closed, which is what makes this a
# valid guard for the non-interactive bootstrap path: a read at EOF must not
# abort the run or silently accept the default.
#
# Two install steps are skipped, because the container cannot support them
# rather than because they go untested elsewhere:
#   --skip-brew   Linux aarch64 has no Homebrew bottles, so a bundle would
#                 build from source for hours.
#   --skip-shell  chsh authenticates over PAM, and the container user has no
#                 password.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SANDBOX_IMAGE="${SANDBOX_IMAGE:-debian:13}"
SANDBOX_NAME="dotfiles-install-$$"
WORK_DIR="$(mktemp -d)"

cleanup() {
    docker rm -f "${SANDBOX_NAME}" >/dev/null 2>&1 || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found. On macOS: brew install colima docker && colima start" >&2
    exit 1
fi

# Resolve the daemon endpoint before swapping configs: an explicit DOCKER_HOST
# wins, then the active docker context, then colima's own socket. That last
# fallback matters because removing ~/.docker deletes the colima context too,
# leaving the CLI pointed at a default socket that does not exist.
if [[ -z "${DOCKER_HOST:-}" ]]; then
    endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"

    if [[ "${endpoint}" == unix://* && ! -S "${endpoint#unix://}" ]]; then
        endpoint=""
    fi

    if [[ -z "${endpoint}" && -S "${HOME}/.colima/default/docker.sock" ]]; then
        endpoint="unix://${HOME}/.colima/default/docker.sock"
    fi

    [[ -n "${endpoint}" ]] && export DOCKER_HOST="${endpoint}"
fi

# Run against a throwaway docker config. The user's own config may name a
# credential helper that is no longer installed (a stale credsStore from an
# uninstalled Docker Desktop breaks even anonymous pulls), and this check needs
# nothing from it: the image is public.
export DOCKER_CONFIG="${WORK_DIR}/docker"
mkdir -p "${DOCKER_CONFIG}"

if ! docker info >/dev/null 2>&1; then
    echo "error: docker daemon is not reachable. Start it with: colima start" >&2
    exit 1
fi

# Ship the commit being pushed, not the working tree.
git archive --format=tar.gz -o "${WORK_DIR}/dotfiles.tar.gz" HEAD

cat > "${WORK_DIR}/guest-install.sh" <<'GUEST'
#!/usr/bin/env bash
# Runs as root inside the container.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# Only sudo is pre-installed: a real host has it, and nothing can apt-get
# without root anyway. Everything else must come from the bootstrap itself.
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq sudo >/dev/null 2>&1

useradd -m -s /bin/bash tester
echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
chmod 440 /etc/sudoers.d/tester

mkdir -p /home/tester/.dotfiles
tar -xzf /tmp/dotfiles.tar.gz -C /home/tester/.dotfiles
chown -R tester:tester /home/tester/.dotfiles

sudo -u tester -H bash -c 'cd ~/.dotfiles && ./install.sh --skip-brew --skip-shell'
status=$?

if [[ "${status}" -ne 0 ]]; then
    printf 'FAIL install.sh exited %s\n' "${status}"
    exit 1
fi
GUEST

cat > "${WORK_DIR}/guest-verify.sh" <<'GUEST'
#!/usr/bin/env bash
# Runs as root inside the container, after the install.
fail=0

check() {
    local desc="$1"
    shift
    if sudo -u tester -H "$@" >/dev/null 2>&1; then
        printf '  ok   %s\n' "${desc}"
    else
        printf '  FAIL %s\n' "${desc}"
        fail=1
    fi
}

check "apt installed git"            bash -lc 'command -v git'
check "apt installed zsh"            bash -lc 'command -v zsh'
check "~/.zshenv applied"            test -f /home/tester/.zshenv
check "~/.config/zsh/.zshrc applied" test -f /home/tester/.config/zsh/.zshrc
check "zsh login exports XDG paths"  zsh -lc '[[ "${XDG_CONFIG_HOME}" == "${HOME}/.config" ]]'
check "no optional installs ran"     bash -lc '! command -v docker && ! command -v tailscale'

exit "${fail}"
GUEST

printf 'sandbox: starting %s as %s\n' "${SANDBOX_IMAGE}" "${SANDBOX_NAME}"
docker run -d --name "${SANDBOX_NAME}" "${SANDBOX_IMAGE}" sleep infinity >/dev/null

docker cp "${WORK_DIR}/dotfiles.tar.gz" "${SANDBOX_NAME}:/tmp/dotfiles.tar.gz"
docker cp "${WORK_DIR}/guest-install.sh" "${SANDBOX_NAME}:/tmp/guest-install.sh"
docker cp "${WORK_DIR}/guest-verify.sh" "${SANDBOX_NAME}:/tmp/guest-verify.sh"

# No -i: stdin stays closed, which is the condition under test.
printf 'sandbox: running install.sh on a bare machine\n'
if ! docker exec "${SANDBOX_NAME}" bash /tmp/guest-install.sh > "${WORK_DIR}/install.log" 2>&1; then
    echo "sandbox: install failed" >&2
    tail -40 "${WORK_DIR}/install.log" >&2
    exit 1
fi

printf 'sandbox: verifying result\n'
if ! docker exec "${SANDBOX_NAME}" bash /tmp/guest-verify.sh; then
    echo "sandbox: verification failed" >&2
    tail -40 "${WORK_DIR}/install.log" >&2
    exit 1
fi

printf 'sandbox: install verified\n'
