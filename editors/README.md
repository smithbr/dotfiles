# editors/

Shared editor settings live once in `editors/`, and nowhere under `stow/`. `editor_dirs` in `scripts/link.sh` lists each editor's user directory per platform, and every file in the matching `editors/` directory is linked there with the same backup rules as stow packages. Add an editor or platform there, not as symlinks in `stow/`.
