# The following lines were added by Docker Desktop to add commands to your PATH.
[[ -d "${HOME}/.docker/bin" ]] && export PATH="${PATH}:${HOME}/.docker/bin"
# End of Docker Desktop section.

if [[ -f "${HOME}/.bashrc" ]]; then
    source "${HOME}/.bashrc"
fi
