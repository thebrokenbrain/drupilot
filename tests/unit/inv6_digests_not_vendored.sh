#!/usr/bin/env bash
# INV6: digests are never vendored or applied blindly, and only a SHA whose
# pass finished is frozen. Owned by M8 (staged digests copy and replay); the
# runtime cache location is covered by L-M0-1.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_skip "INV6 is owned by M8 (staged digests and replay)"
