#!/usr/bin/env bash
# INV3: tests are never relaxed and verdicts never fabricated (negative controls
# + the preservation enum). Owned by M4: the G-E2E skeleton runs the suite in
# DDEV and checks the verdict; the enum is frozen by the M1 contract snapshot.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_skip "INV3 is owned by M4 (G-E2E skeleton)"
