#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

log_info "Starting macOS bootstrap"
