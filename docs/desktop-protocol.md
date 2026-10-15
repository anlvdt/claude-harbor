# Desktop protocol v1

The Swift app calls `manager.py --desktop-api 1 COMMAND ARGS...`. Ordinary commands without this prefix retain their direct JSON result shape and nonzero exit status on failure. No new account storage or credential copying is introduced.

Success (exit 0):

```json
{"protocolVersion":1,"ok":true,"result":{"profiles":[]}}
```

Failure (exit 1):

```json
{"protocolVersion":1,"ok":false,"error":{"code":"store_busy","message":"Dữ liệu đang được app hoặc thao tác khác sử dụng.","remediation":"Chờ thao tác hiện tại hoàn tất; đóng các profile trước khi sửa hoặc phục hồi."}}
```

`capabilities` returns `protocolVersion` and the feature names `structured_errors`, `profile_health`, `recovery_status`, without reading profile data. Startup requires these capabilities. Swift checks every envelope's version, success flag, result/error and exit status. Invalid or legacy responses fail closed without displaying raw response bytes. Unknown Python exceptions become a fixed `operation_failed` message; the protocol does not forward exception text or raw stderr. Timeouts and output bounds remain enforced by the Swift runner.

Known error codes and Vietnamese remediation live in `backend_protocol.py`. `manager.py` assigns domain errors at command boundaries; deeper unexpected failures use the safe generic fallback. Human-readable messages are not used to infer codes.

`status` adds `health` per profile and top-level recovery `issues`. Lightweight clone checks run during refresh; `doctor` additionally verifies signatures. `check` rejects selected stale clones and pending recovery before the UI closes apps. Existing file locks, launch leases, binding validation, journal and rollback remain authoritative at write time. The UI's busy state is not a data lock.

Sync phases: checking → waiting if a turn is active → closing → syncing → verifying → reopening. Cancellation is offered only while waiting. Fresh verification runs with profiles still closed. A verification error after successful sync is reported as such; it does not imply that the committed writes were rolled back. After successful verification, the UI reopens only apps that were running beforehand and reports launch failures separately. If post-write verification fails, those apps remain closed for deliberate review. Refresh failure disables further operations until a successful refresh.

Manager verification saves `last-verification.json` atomically with private file permissions while holding the sync lock, before returning success or `verification_failed`. Desktop errors do not include raw diagnostic paths; remediation names the local report available through **Báo cáo & sao lưu**.

Repair and recovery require explicit user actions. The backend refuses them while profiles are running. No automatic repair, cross-provider switch, new sharing group or updater is part of this protocol.

Tests: `python3 -m unittest test_backend_protocol`; compile/run `tests/BackendProcessTests.swift` with `AccountManager.swift`, `HarborUI.swift`, `AddProfileSheet.swift`, `HistoryUI.swift`, `Localization.swift` and `-D BACKEND_TEST -parse-as-library`. The Swift suite stages the real dispatcher/generation in a temporary home and overrides only child-process environment, preserving the test runner's environment and real accounts.

History import is available through a source picker, optional Desktop metadata picker and explicit target confirmation. Import writes are followed by verification. Independent verification and the read-only report/activity viewer use the same operation guard. Import source checks return `import_source_busy` or `import_source_unchecked` when a visible writer or an inspection failure prevents admission. The bounded activity log stores only dates, categories, outcomes and counts.

Upcoming 0.4.0: Harbor localizes stable backend error codes at the Swift boundary without changing protocol v1 or CLI JSON. English uses a fixed catalog and a safe generic fallback for unknown codes. Vietnamese preserves backend messages. Stored language preference changes presentation only; it never changes profile selection, invokes sync, or rewrites history.

`check` now optionally includes `busyDetails`, matching the legacy `busy` array, with profile ID, reason (`reply_in_progress`, `session_writing`, `uninspectable_session`) and an optional original session title. The UI translates reason codes and keeps names/titles intact. Older responses without this field use a localized generic waiting message in English. The existing CLI `busy` strings are preserved.
