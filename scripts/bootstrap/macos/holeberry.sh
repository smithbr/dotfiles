#!/usr/bin/env bash
# Installs Holeberry, a Pi-hole menu bar app with no Homebrew cask, from its
# latest release DMG once codesign and spctl accept it. An installed copy
# updates itself and is left alone. HOLEBERRY_APPS_DIR overrides the
# destination.
# https://github.com/pedrovieira/Holeberry
# detect: [[ -d "${HOLEBERRY_APPS_DIR:-/Applications}/Holeberry.app" ]]
# default: off

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

REPO_API="https://api.github.com/repos/pedrovieira/Holeberry/releases/latest"
TEAM_ID="5UN5GTF749"
APPS_DIR="${HOLEBERRY_APPS_DIR:-/Applications}"
APP="${APPS_DIR}/Holeberry.app"

if [[ -d "${APP}" ]]; then
    log_info "Holeberry already installed at ${APP}; it updates itself"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/holeberry.XXXXXX")"
MOUNT="${WORK}/mnt"
attached=0
cleanup() {
    if [[ "${attached}" -eq 1 ]]; then
        hdiutil detach -quiet "${MOUNT}" 2>/dev/null || hdiutil detach -quiet -force "${MOUNT}" 2>/dev/null || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

# Read without jq, which may not be installed yet.
url="$(curl -fsSL "${REPO_API}" \
    | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
    | head -n 1 | sed 's/.*"\(https[^"]*\)"$/\1/')" || true
if [[ -z "${url}" ]]; then
    die "No Holeberry DMG in the latest release; see https://github.com/pedrovieira/Holeberry/releases"
fi

spin "Downloading ${url##*/}..." curl -fsSL -o "${WORK}/Holeberry.dmg" "${url}"

mkdir -p "${MOUNT}"
if ! out="$(hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "${MOUNT}" "${WORK}/Holeberry.dmg" 2>&1)"; then
    die "Could not open ${url##*/}: ${out}"
fi
attached=1
[[ -d "${MOUNT}/Holeberry.app" ]] || die "${url##*/} has no Holeberry.app"

team="$(codesign -dv "${MOUNT}/Holeberry.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "${team}" != "${TEAM_ID}" ]]; then
    die "Holeberry.app is signed by team '${team:-none}', not ${TEAM_ID}; not installing it"
fi
codesign --verify --deep --strict "${MOUNT}/Holeberry.app" \
    || die "Holeberry.app failed its signature check; not installing it"
spctl --assess --type execute "${MOUNT}/Holeberry.app" \
    || die "Gatekeeper rejects Holeberry.app; not installing it"

mkdir -p "${APPS_DIR}"
ditto "${MOUNT}/Holeberry.app" "${APP}"
log_info "Holeberry installed at ${APP}; open it to add your Pi-hole"
