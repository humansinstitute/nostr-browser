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

For Autopilot work, read the installed `wingman-sessions` skill; for Flight Deck tasks or supervised dispatch also read `flight-deck-workflow` and its dispatch reference before updates/briefs. Local entrypoints: `/Users/mini/.codex/skills/wingman-sessions/SKILL.md` and `/Users/mini/.codex/skills/flight-deck-workflow/SKILL.md`; use the harness’s installed equivalents when available.

Check your own queue before starting, at milestones/decisions, validation and handoff: `bun /Users/mini/code/wm/autopilot/clis/wingman.ts session queue list`. Read complete items and referenced authoritative records. Immediately consume only exact revisions incorporated into context/plan with `session queue consume <id> --revision <read-revision> --reason <incorporation-reason>`. Consumption is not completion: retain unfinished obligations on the task/plan; leave unrelated/unincorporated/newer items pending. If consume is denied, use the skill’s verified alias-compatible acknowledge fallback and report the gap. Preserve conflict and uncertain-delivery safeguards; never clear blindly or consume merely to suppress turns.

Every worker brief includes manager session ID, Autopilot location/connection, exact supported communication command and task/report destination. Workers ask questions; managers retain worker IDs, check their own queue and worker progress, and answer the exact worker. Use authorized `bun <autopilot-checkout>/clis/sessions.ts send <target-session-id> "<worker session/task; decision; recommendation; blocking status>" --bot-crypto --json`; queue-add only when specifically authorized. Sending may queue while busy; no immediate interrupt guarantee. Continue independent work while awaiting answers and pause dependent decisions.

Own queue management never authorizes consuming another session’s queue. Callback inboxes remain separate: review evidence and follow up, then acknowledge/close only reviewed callbacks. No runtime injection, scope bypass or background polling is implied; recheck before handoff.
