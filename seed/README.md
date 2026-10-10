# seed/

`seed/<layer>/` and `seed/<layer>.<os>/` hold files an application rewrites itself (Docker's and gh's config). They are copied once with mode 600 when missing and never overwritten; do not move them into `stow/`.
