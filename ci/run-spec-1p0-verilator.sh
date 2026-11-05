#!/usr/bin/env bash
# Copyright 2026 10xEngineers.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_DIR="${SPEC_1P0_BUILD_DIR:-${ROOT}/build/spec-1p0-verilator}"

"${ROOT}/ci/run-single-top-verilator.sh" \
  "${BUILD_DIR}/three-hart" tb_dm_top_spec_1p0 \
  -GNrHarts=3 -GBusWidth=32

"${ROOT}/ci/run-single-top-verilator.sh" \
  "${BUILD_DIR}/four-hart-bus64" tb_dm_top_spec_1p0 \
  -GNrHarts=4 -GBusWidth=64
