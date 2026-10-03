# Security audit findings

Ranked from most to least likely to be accepted:

1. [Predictable world-readable diagnostic logs disclose local system information](01-predictable-diagnostic-logs.md) — a local account can read another user's fixed-name mode-0644 debug and journal bundles without winning a race.

Non-exploitable or defense-in-depth observations are collected in [hardening notes](hardening-notes.md).

The two issues identified as already reported in the audit request (the `arch-mact2` `SigLevel = Never` repository and the Quattro upgrade's persistent `Optional TrustAll` state on re-run) are intentionally not duplicated here.
