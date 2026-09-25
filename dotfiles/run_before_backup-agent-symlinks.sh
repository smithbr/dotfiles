#!/usr/bin/env bash
# Back up real files sitting where chezmoi wants to create an agent symlink.
#
# The symlink_ entries in this repo point ~/.claude, ~/.codex, ~/.cursor and
# friends at ~/.config/agents. When one of those paths already exists as a real
# file or directory, `chezmoi apply` deletes it and writes the symlink over the
# top, with no backup and no prompt. That is easy to hit: every agent CLI writes
# its own config on first run, so launching Claude Code once before applying the
# dotfiles is enough to put a real ~/.claude/settings.json in the way.
#
# Move anything like that aside first so the content stays recoverable. chezmoi
# then creates the symlink onto a clear path.

set -euo pipefail

source_dir="${CHEZMOI_SOURCE_DIR:?CHEZMOI_SOURCE_DIR is not set}"
# The destination, not $HOME: chezmoi honours --destination, and a backup
# written outside the tree it was told to manage would be wrong (and would
# make this script untestable against a scratch directory).
dest_dir="${CHEZMOI_DEST_DIR:?CHEZMOI_DEST_DIR is not set}"
backup_root="${dest_dir}/.local/state/dotfiles/clobbered"
stamp="$(date +%Y%m%d-%H%M%S)"
backed_up=0

# Map a chezmoi source path to its target path: drop the .tmpl suffix, then the
# attribute prefixes from each path component. Checked against
# `chezmoi target-path` for every symlink_ entry in this repo; calling chezmoi
# itself here would re-enter it while apply holds its state lock.
target_path_for() {
    # Attributes stack (private_dot_claude, readonly_private_dot_ssh), so strip
    # them in a loop until none are left, and only then map dot_ to a leading
    # dot -- doing dot_ first would turn private_dot_claude into dot_claude.
    printf '%s' "${1#"${source_dir}"/}" | sed -E \
        -e 's/\.tmpl$//' \
        -e ':a' \
        -e 's#(^|/)(symlink_|private_|exact_|readonly_|executable_|encrypted_|literal_)#\1#g' \
        -e 'ta' \
        -e 's#(^|/)dot_#\1.#g'
}

while IFS= read -r source_path; do
    target="${dest_dir}/$(target_path_for "${source_path}")"

    # A symlink is chezmoi's own work from a previous apply (or a stale one it
    # is about to retarget), and a missing path is the fresh-machine case.
    # Neither loses data. Only a real file or directory is about to be deleted.
    if [[ -L "${target}" ]] || [[ ! -e "${target}" ]]; then
        continue
    fi

    backup="${backup_root}/${stamp}/${target#"${dest_dir}"/}"
    mkdir -p "$(dirname "${backup}")"
    mv "${target}" "${backup}"
    printf 'Backed up %s -> %s\n' "${target}" "${backup}"
    backed_up=1
done < <(find "${source_dir}" -name 'symlink_*' -print | sort)

if [[ "${backed_up}" -eq 1 ]]; then
    printf 'These paths are now symlinks into ~/.config/agents; the originals are kept above.\n'
fi
