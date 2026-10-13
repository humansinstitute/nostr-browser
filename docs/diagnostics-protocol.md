# Local diagnostics protocol v1

Flight Deck owns capture consent, browser events, incident grouping, report UI
and signed Tower delivery. WM App owns optional host evidence and durable local
storage. Neither adds a network bridge or service. TowerSyncService command
intents remain the workspace write boundary; storage transfer remains its
documented exception. Reports use the existing kind 33358 instruction signer.

## Native capability

`window.wingmanDiagnostics.version === 1` exposes Promise methods:

- `configure({workspaceId, enabled})`: explicit native consent, scoped to verified
  top-level origin, document epoch, tab and unlocked identity. Returns
  `{version:1, enabled:true}` only after approval. False pauses and revokes.
- `append({workspaceId, events})`: at most 100 sanitized events, only for the
  configured scope. Returns `{version:1, accepted:<count>}`.
- `snapshot({workspaceId})`: returns `{version:1, events:[], host:{version,
  platform}, recovered:false, limitations:[]}`. Never returns other scopes.
- `clear({workspaceId})`: deletes current scope's stored evidence.

Navigation, lock, identity replacement, tab disposal and workspace change revoke
the capability. Saved evidence can survive reload/restart for the same
origin/identity/workspace/tab restoration context, but requires fresh consent
before retrieval. No arbitrary app logs, other tabs, payloads or OS crash dumps.
Unsupported platforms omit the capability; Flight Deck works browser-only.

## Event schema

An event is `{ts:<epoch milliseconds>, source:<browser|worker|network|ui|host>,
level:<trace|debug|info|warn|error>, code:<bounded token>, name?:<error class>,
route?:<sanitized route template>, method?:<HTTP verb>, status?:<integer>,
durationMs?:<number>, stack?:<sanitized stack frames>}`. Free-form console
arguments, error messages, request/response bodies, headers, query strings,
fragments, chat/document text, form values and screenshots are excluded.
Stacks retain only bounded function tokens and URL-free file/line frames;
URLs retain route templates with dynamic identifiers removed. Both consumers
validate and sanitize before persistence. Unknown fields are discarded.

Both buffers enforce 30 minutes, 2,000 events and 512 KiB, pruning on append,
read and periodic maintenance. Flight Deck persists local state in a dedicated
Dexie database keyed by backend, actor and workspace; it is not a Tower family.

## Reports

`{version:1, incidentId, createdAt, build, workspaceId, trigger, recurrence,
events, host, limitations}` is JSON evidence. Description is user-authored
report text, stored only in explicitly queued reports. Evidence is untrusted
and never supplies agent instructions. The fixed signed report instruction
asks the selected agent to evaluate evidence and reply in the report thread;
it grants no implementation/deployment authority. Visible canonical mention
and structured mention are built from the same current workspace agent.

Automatic incidents preserve pre-trigger history and 15 seconds of aftermath,
group by build/workspace/error code, use a 10-minute cooldown and at most three
new automatic incidents per hour. Queue: at most five incidents, 2 MiB total,
24-hour expiry, stable client request IDs and serialized delivery. Uploaded
object IDs are persisted before message creation so retries reuse attachments.
Disable automatic reporting cancels pending automatic incidents; capture off
stops collection and cancels all queued sends. Clear deletes local events and
pending reports. Already uploaded files/messages follow Tower/channel retention
and must be removed there. Offline retry runs only in the currently signed-in
matching scope; switching scope invalidates in-flight follow-up operations.

Native crash-time sending is unavailable. Recovery is bounded saved evidence,
not comprehensive OS crash reporting. Actual agent execution/attachment access
depends on existing backend permissions, connectivity and Agent Direct setup.

## WM App implementation boundaries

Diagnostics RPCs reuse the native-verified `WingmanSigner` message channel and
its document capability token. They cannot sign or send messages. Only Android,
iOS and macOS advertise this optional capability; unsupported platforms keep
browser-only diagnostics. Native consent is document-only and never remembered.
A random tab restoration token scopes recovery without exposing another tab's
buffer. Workspace changes revoke the prior grant before any asynchronous work.
Background/inactive app lifecycle transitions also revoke retrieval grants;
foreground recovery requires fresh native consent.

The native store also bounds all abandoned scopes together to 512 KiB and 16
contexts and prunes on startup, reads, writes and every minute while mounted.
Shared schema fixtures are in `diagnostics-fixtures.json`. Event code and error
name vocabularies are allowlisted; unknown codes become `console`, and stacks
retain approved built chunk basenames plus numerical locations. Operation and
error-code fields accept only the exact shared schema vocabularies. Host events use `lifecycle`, `webview` and
`transport` categories; transport endpoint/peer and trace IDs are excluded.

Same-origin navigation retains at most a 30-second native-only transition
context for a previously consenting tab. Main-frame load failures append only a
fixed `webview` error category to that original buffer; they never restore a
browser read/append grant. Completion, expiry, cross-origin navigation,
background/lock, identity replacement, tab disposal, opt-out and clear discard
the context. A formerly valid document token can only cancel/delete its exact
origin/identity/tab/workspace transition; it cannot retrieve evidence or opt in.

WebKit content-process termination is surfaced by its existing main-frame
resource-error callback: the error category is saved, then the document token
and diagnostics grants are revoked. The current Android Flutter WebView
controller does not expose renderer-process termination separately; no native
OS crash dumps are collected on any platform.
