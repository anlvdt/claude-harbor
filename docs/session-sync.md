# Session synchronization

Harbor isolates each profile's GUI and Code directories. It does not share a live transcript file between processes. Sync is opt-in: only profiles whose **Sync** control is selected participate.

1. Resolve the signed-in Code identity for each selected profile. Pending and unselected profiles are excluded until selected explicitly.
2. Check clone health, pending recovery journals, active Claude SDK processes and saved completed-turn markers. Wait for active replies, with cancellation available during this stage.
3. Ask the running Claude apps to terminate normally. Refuse to write if a process remains open.
4. Hold an exclusive sync lock. Launcher processes wait on this lock before starting Electron.
5. Recover any interrupted sync transaction, then take stable snapshots of managed Desktop records, transcript chains and allowed per-session files. Normal sync never scans an external Code store.
6. Compare stable user/assistant message signatures. Extend prefix histories; preserve divergent maximal histories as separate branches, preserve prior-session chains, and keep tombstoned records excluded.
7. Before every mutation, append and fsync a write-ahead journal entry with a backup and expected input digest. Preserve target settings/model/permissions and never copy source login state. Commit only after verification.
8. Reopen only apps that were running before the sync and show counts plus any audit warnings.

Readable archived sessions are included when their records remain active. An unavailable transcript, malformed record, ambiguous transcript ID or empty transcript produces an audit entry instead of a false success. `history-audit.json` can contain private project paths and titles; do not attach it publicly without reviewing/redacting it.

The backup directory is accessible through **Báo cáo & sao lưu**. Automatic rollback handles a failed write transaction; the next sync also recovers an active journal before it writes. `manager.py recover` is available when recovery must be run while all profiles are closed. There is not yet a user-facing rollback browser for choosing an earlier successful sync.

Importing an external local history is a separate CLI action. It requires an explicit `--source` Code root and explicit `--to` selected profile IDs; Harbor does not treat an unregistered account or `~/.claude` as an implicit sync source.

Account-bound MCP permissions are not cloned from the source. Workspace files stay in their original locations; Harbor syncs session history rather than copying a project checkout. Tools may require renewed permissions in the target account.

## Incomplete or damaged Code history

An `Unterminated string` error can occur in Code data when a JSON record or transcript line is incomplete. A malformed Desktop record blocks writes to that profile; a malformed transcript excludes that session from the current sync. Harbor retains the original bytes and reports the affected file and line in `history-audit.json`, available through **Báo cáo & sao lưu**. Healthy profiles and sessions can continue, and the manager reports warnings for the skipped data.

If the damaged file is `sync-state.json`, Harbor stops with its path and decode location instead of discarding the lineage. This manifest controls branch membership and sharing restrictions; resetting it automatically could change sync behavior.

## Upgrading from v0.1.0

Replace the Harbor app with v0.2.0 and open it once to install the new backend. The existing registry, account login and history remain in the same Application Support directory. Choose **Sync** explicitly on the profiles that may share history.

Use **Kiểm tra** to inspect older clones. v0.1.0 clones lack the recorded source version used by the new health checks, so repair them before syncing. Close all profile apps, then run the backend dispatcher's repair command for each profile ID from `profiles.json`:

```sh
python3 "$HOME/Library/Application Support/ClaudeHarbor/manager.py" repair PROFILE_ID
```

For installations retaining the prototype data directory, substitute `ClaudeThreeDesktop` for `ClaudeHarbor`. Repair rebuilds the app from `/Applications/Claude.app` while retaining the profile ID, login, history and sync selection. Reopen profiles after repair.

## Magpie preset

The preset uses a loopback Anthropic-compatible gateway at `http://127.0.0.1:3425`, loopback key `magpie-claude-desktop`, and the Desktop remapped model ID `mythos-magpie-1026517788`. The loopback key is a gateway convention, not a user credential. Keep the gateway running. This preset was validated on the original installation; remapping and upstream model availability can change between Magpie versions.

## Compatibility

Cloning and history import rely on Claude Desktop's current local storage and Electron bundle layout. The clone preserves the internal `CFBundleName=Claude`; vendor frameworks stay signed, while the native wrapper and outer app are signed ad-hoc with JIT/library validation entitlements. The release includes only Harbor code, its own icon and runtime scripts. It never includes Claude.app, Claude's icon, account databases or conversation transcripts.
