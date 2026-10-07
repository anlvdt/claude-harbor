# Audit fixes — implementation plan

Scope: fix confirmed F01–F10 and the defensive lifecycle/data-boundary gaps from the reviewed audit. Preserve Swift/AppKit + Python and existing account data. Feature roadmap (cross-device sync, multi-provider UI, complete session browser) is not part of bug remediation.

1. Reproduce data bugs with isolated fixtures: tombstones, prior chains, cache collisions, auxiliary changes, malformed records and external authorization.
2. Capture immutable input bytes; preserve stable lineage IDs; persist source-target restrictions; block unknown ownership rather than rediscover it.
3. Journal backups/intent durably before writes, make rollback restartable, gate startup/relaunch on recovery, verify without cache.
4. Keep launch leases across exec; publish immutable runtime generations; expose profile selection and doctor/repair; bound/drain backend output.
5. Run Python suite, Swift process tests and build/sign verification. Document remaining real-Claude compatibility checks without claiming they passed.
