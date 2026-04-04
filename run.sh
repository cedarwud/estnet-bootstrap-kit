#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT

cd "${PROJECT_ROOT}"
exec "${PROJECT_ROOT}/tools/start_omnetpp.sh" "$@"
