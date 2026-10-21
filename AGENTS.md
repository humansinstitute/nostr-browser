# Repository guidance

## Universal browser FIPS transport invariant

`window.fipsTransport` is the only WMapp browser capability for an HTTPS or
approved local application to reach FIPS services. Do not add Tower-,
Autopilot-, Drive-, GRASP-, Git-, HTTP-, SSE-, worker-, download-, or
WebSocket-specific browser network bridges. Direct navigation to a `.fips`
WApp remains a separate WMapp routing path.

The provider must fail closed and preserve explicit top-level-origin consent,
exact FIPS endpoint and peer pinning, endpoint-scoped concurrent grants,
streaming/cancellation, and navigation/identity/lock/tab lifecycle revocation.
Authentication, request signing, and service protocol verification stay above
the transport. Native callers must reuse the same generic FIPS socket transport
and security semantics; they must not grow service-specific network stacks.

Service authentication approval is distinct from transport consent. Native
"Always allow" decisions for either capability remember only versioned policy
rules scoped to the verified top-level origin, active device identity, exact
FIPS endpoint/peer/port, transport purpose, and capability class; signing rules
also include the authentication protocol and operation. They must never cache
or replay a signature: every allowed NIP-98 request is freshly signed for its
exact URL, method, and body. Mismatched or revoked document/handle state fails
closed.

`window.wingmanTowerTransport` is compatibility-only and must be implemented as
an adapter over `window.fipsTransport`. New consumers must not use it. Remove
the adapter after the tracked Flight Deck migration is complete.

Store operational agent handoffs, worker briefs, installation results, screenshots,
and run-specific validation evidence only under ignored `tmp/docs/handoffs/`.
Do not create tracked handoff directories elsewhere or force-add ignored files.
Legacy `docs/handoffs/` and handoff filenames under `docs/` are ignored to prevent
accidental reintroduction.

Keep general product documentation, reusable validation procedures, and code in
Git. Use generic device labels and placeholders; never copy personal device names,
serial numbers, UDIDs, or device UUIDs into tracked files, commit messages, or
task reports. Public docs should describe procedures without linking private
local evidence files.

Preserve existing local records byte-for-byte when moving them. If a destination
exists with different content, retain both under distinct names and verify hashes.
Keep privacy audits, replacement data, and history backups ignored and private.
Ordinary deletion does not purge Git history. Prepare history rewrites in an
isolated local mirror and obtain explicit authorization before changing shared
history or deleting remote refs.

## Active session queue handling

When running in an Autopilot session, inspect your own pending prompt queue at meaningful milestones during active work, when new work is reported, and before final handoff, using `bun /Users/mini/code/wm/autopilot/clis/wingman.ts session queue list`. Read each complete item and any referenced authoritative thread/task. Incorporate applicable steering; immediately consume only the exact item and revision actually incorporated using `bun /Users/mini/code/wm/autopilot/clis/wingman.ts session queue consume <id> --revision <read-revision> --reason <incorporation-reason>`. Consumption removes pending work while preserving history; merely listing or reading is not consumption. Keep unfinished/unrelated work and concurrent newer arrivals pending. Never clear the queue blindly or consume solely to suppress a follow-up turn. Recheck before handoff.

Supervised worker callbacks are separate: inspect `bun /Users/mini/code/wm/autopilot/clis/wingman.ts dispatch inbox`, review actual evidence and report/take necessary follow-up, then acknowledge and close only reviewed callbacks. Do not apply these commands to another session or imply monitoring after the process stops. Follow `/Users/mini/.codex/skills/wingman-sessions/SKILL.md` for revision conflicts and uncertain delivery, with Pete's explicit consume-on-incorporation policy taking precedence over older completion-only acknowledgement guidance.
