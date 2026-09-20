# Durable sync and device conflicts

## Local persistence

Account data and the outbox use one encrypted SQLite database. SQLite runs in a
worker isolate with WAL, `synchronous=FULL`, and `fullfsync` where supported.
A local save commits its entity, derived counters/recovery state and outbox
intent in one transaction before publishing success or starting HTTP. A failed
commit keeps the previous state and the form's draft. This replaces the stronger
durability assumption previously made about SharedPreferences, whose
[official contract](https://pub.dev/packages/shared_preferences) explicitly
excludes critical data. SQLite's [synchronous modes](https://www.sqlite.org/pragma.html#pragma_synchronous)
define the storage guarantee; defective hardware and loss of the device remain
outside it.

Values retain AES-GCM encryption with the account/slot name authenticated as
associated data. The key stays in the OS keystore. Existing account slots and
key-lifecycle metadata migrate together in one transaction; only a successful
commit permits preferences cleanup. An import marker prevents old preferences
from restoring deleted data. Unreadable queues block mutation instead of being
replaced with an empty queue. Appearance and other noncritical preferences still
use SharedPreferences.

Versioned snapshots and compare-and-swap commits coordinate foreground and
background database connections. Confirmed source deletion fences training
checkpoints, including deletion followed by re-adoption of identical content.
Logout invalidates the initiating session's claim before purging its namespace;
a later login cannot be purged by an old cleanup callback.

## Delivery protocol

The new client sends every durable operation through `apply_sync_operation`.
The authenticated account and operation UUID identify an immutable request. A
server transaction applies its effect and stores the result together. Repeating
the UUID returns that exact effect result; changing its kind, identity or payload is
rejected. Account A cannot inspect or spend account B's operation identifiers.

The local queue must persist the operation before sending, retain its UUID and
payload after an uncertain response, and keep later operations for that entity
blocked until its receipt is known. An operation UUID alone cannot order a
delayed **first** request. Foreground and background delivery share that queue,
claim mechanism and receipt reconciliation. An old receipt must never replace
a newer local intent. Missing server RPCs leave durable work pending; they do
not enable direct-write fallback.

Before the first request, the exact normalized RPC payload and its schema
version are committed to the operation. Retries reuse that payload even after a
timezone change or client upgrade. Instants are recorded in UTC, while meal
calendar days and slots retain their original meaning. An acknowledgement
reconciles the entity and removes its intent in one local transaction. Failed
delivery never drops an accepted intent because of its age or attempt count.
Automatic delivery stops after eight counted failures (64 for deletion
operations), retaining the blocked intent until an explicit retry. Network and
timeout failures do not consume that budget.

## Reconnection and background execution

An available-network transition triggers foreground replay. Resume and manual
retry remain available; connectivity is only a trigger, not proof that the
server is reachable. Settings show pending work and distinguish a blocked
backend/protocol or capacity failure from a successful remote acknowledgement.
An unreadable local queue is shown as unknown, never as an empty pending count.

Android WorkManager and iOS BGTaskScheduler use the same encrypted database,
dispatcher and account/session claims. A background run handles at most twenty
operations within twenty seconds. It reads an existing session with over two
minutes of token validity and the logout journal, never refreshes credentials or writes a new auth session, and
rechecks permission before HTTP and acknowledgement. Follow-ups are bounded to
three attempts after 15, 30 and 60 minutes for retryable runs. An accessible
encryption key and completed foreground migration are prerequisites. An
unavailable session/key/database does not schedule follow-ups; reopening the
app allows authentication renewal and initialization. The OS controls execution timing;
this is not a promise of immediate synchronization while the app is suspended.
Native registration/builds and simulated runner tests do not establish physical
device scheduling behavior.

The response separates immutable `result` from `current_state`, read under the
same account lock on every call. A receipt for an earlier insertion does not
assert that its entity still exists. Current recipe revisions/content, deletion
states, planned meals and lifetime statistics reconcile the cache; the original
recipe effect revision alone rebases its exact queued successor. Conversion
receipts also report a separate current diary deletion, preserving the consumed
plan without resurrecting a subsequently removed diary entry.
The first conversion also respects an existing diary tombstone: it preserves
the consumed plan, creates no diary row, and spends no counter or tracked day.
The legacy conversion endpoint shares the same account lock and check.

`load_sync_operation_receipt` resolves an operation acknowledged by another
engine without replaying it. It returns only the authenticated owner's receipt,
combined with current state under the same account lock. Unknown or foreign
operation identifiers return null. This lets an open recipe detail follow its
exact conflict copy, including a copy deleted after acknowledgement.

## Conflict policy

| Data | Different new operations | Repeated operation |
|---|---|---|
| Own recipes | Server revision CAS; a stale edit creates a deterministic conflict copy; a stale delete preserves the current recipe. | Exact original receipt; no second copy or rewrite. |
| Diary edits, training plan edits, profile settings | Last server arrival wins. These are **not** protected by document CAS. | Never re-applies an older write over a newer operation. |
| Favorites, shopping checks | Explicit last-arrival register. A new favorite upsert can deliberately re-add a deleted favorite. | An old upsert/delete cannot rewind the register. |
| Weight samples, training completions | Immutable identity-based inserts. Training completion deletion has a permanent receipt. | Original outcome; no duplicate sample or completion. |
| Diary and manual training plan deletion through the new dispatcher | Permanent identity tombstone. A distinct replacement needs a new identity. | Original outcome. |
| Coach training plan adoption/deletion | Stable source identity plus an explicit incarnation; deletion is terminal for that incarnation. | Never recreates or deletes a later incarnation. |
| Planned meals | Removed and consumed states are terminal, including the legacy plan RPC. | Original conversion receipt, including its diary/statistics outcome. |
| Counters and tracking day | Existing atomic counter and monotone day RPCs; a meal/weight insert counts in the same transaction. | Persistent operation receipt; source-derived counter IDs also match legacy replay follow-ups. |

Distinct device edits to profiles, diary records or training documents can still
replace each other. This release defines that policy; it does not implement a
field merge or a conflict editor for those document types.

Coach plans retain their stable message-derived ID for cross-device deduplication.
`source_id` identifies the proposal and `incarnation` identifies a deliberate
adoption. The account-owned source head records its current incarnation and
deletion state. A new explicit adoption after a known deletion uses the next
incarnation; an old operation never increments it as part of retry. Edits within
an active incarnation retain the documented last-arrival policy.

Local source heads, plans and queued intents commit together. A stale or unknown
adoption that conflicts with a server head remains a saved draft with its exact
blocked operation. Training offers **Review adoption**: load the current head,
inspect the retained draft and explicitly save against that head. Another
concurrent change can require another review. Review binds to the latest confirmed
unsent edit in that incarnation; another local edit before the atomic commit
invalidates the confirmation instead of replacing it with an older draft.
Manual global retry cannot silently
resolve this state. **Discard draft** is a separate confirmed local transaction
that works offline and leaves the server plan alone; already frozen requests and
operations for other incarnations are preserved. Selection and workout checkpoints
remain bound to their source incarnation.

## Recipes

`FitnessRecipe.serverRevision` is the last observed server revision. Zero means
an explicit new identity; null means an unversioned legacy draft. Revisions are
monotone per account and may contain gaps. Device clocks are never compared.
Random UUID slugs separate simultaneous new recipes; existing slugs remain valid.

The recipe mutation carries `expected_revision`. An exact match updates/deletes
the identity. A missing identity accepts a new draft. A mismatched upsert retains
the original and stores the candidate as `user_conflict_<operation UUID>` with
`conflict_of`; retrying yields the same copy. A mismatched delete changes no
recipe. Restoring a historical version is an explicit new mutation against the
currently observed revision, including a deletion revision. Concurrent restoration
therefore preserves both candidates.

`load_recipe_page` fixes a watermark on its first call. Pages select the last
journal event per slug at or before that watermark and return only live recipes.
The stable slug cursor and at most 200 rows per response exclude later inserts
without losing recipes edited/deleted between pages. Only a completely received
snapshot is authoritative. Local drafts with unknown provenance and pending
operations must not be discarded merely because a snapshot lacks their slug.

`load_recipe_history` returns at most 50 journal events, newest revision first,
with an exclusive revision cursor. A null slug exposes the account-wide history,
including deleted recipes. Tombstones retain the last content for recovery.
A deletion recorded before any server content existed has no restorable version;
the timeline identifies this marker and retains its exact event in the export. All
history, clocks, receipts and deletion identities cascade on account deletion;
the recipe history also belongs in the user's data export. Image references are
local markers, not uploaded image bytes: history cannot transfer device-local
photos to another device.

`load_recipe_photo_refs` pages distinct historical local markers at a fixed
watermark, at most 200 per response. Local photo cleanup waits for both a complete
recipe snapshot and complete historical references; it keeps their union with
pending/local references. Deleting a current recipe does not immediately delete
an image needed by its history.

## Legacy clients and rollout

Apply the new migrations in timestamp order before releasing the new client.
Training writes send an explicit top-level protocol capability so an older RPC
rejects them before applying an effect instead of ignoring incarnation fields.
The migrations backfill
existing recipes under a table lock and retain the old write endpoints. Legacy
recipe edits/deletes are journaled; they cannot supply CAS because they have no
base revision. Their overwritten content remains available in the visible history.
A legacy insertion after a recipe tombstone is redirected to a deterministic
copy instead of resurrecting the deleted identity.

Legacy training writes cannot bypass an incarnation's deletion or overwrite a
later incarnation. Re-adoption therefore requires the updated client. Legacy
direct writes to the remaining tables retain their old last-write-wins behavior.
The dispatcher cannot give those old endpoints universal idempotency or delete
protection. Legacy counter receipts that had already expired before this rollout
cannot be reconstructed retrospectively.

The source [privacy notice](../PRIVACY.md) describes retained recipe history and
operation results. Reconcile the separately hosted notice before releasing this
new persistence behavior; editing this repository does not publish that page.

## Capacity and recovery

The local queue accepts at most 500 pending operations per account. A single
save may create several operations. Exceeding that limit rejects the entire new
transaction while preserving all previously confirmed entities and intents.

History and operation receipts are permanent. There is no age-based pruning:
removing a receipt would let an old offline request run again. Each account has
100,000 recipe revision allocations, 100,000 operation receipts, a 64 MiB history
allowance and a 32 MiB receipt allowance. Backfilled accounts receive their existing
history bytes **plus** the full 64 MiB allowance, preserving room for subsequent
edits/deletions. Recipe rows remain subject to their existing 5,000-active-row cap.
Training source heads are bounded at 100,000 per account and retain only the
source, stable ID, incarnation and deletion state. They cascade on account
erasure and cannot be pruned while old offline operations may return.

Exhausting the new history/receipt budgets rolls back both the effect and
receipt and returns `PT507`, mapped to
`SyncCapacityException`. The client retains the draft/operation and presents a
blocked storage-limit state requiring support; it must not drop the operation,
claim success, or endlessly describe the problem as temporary offline delivery.
The existing 5,000-active-recipe cap instead returns `22023` and is displayed as
a rejected server operation, with the local draft and intent still retained.
An operator can raise an account's history byte budget after reviewing storage
capacity. Raising the other fixed limits requires a reviewed backend migration.
Any future compaction needs a protocol/installation fence proving older requests
cannot return; deleting old receipts or tombstones on a timer is unsafe. Account
erasure remains available even at capacity.

Real PostgreSQL assertions live in `test/migrations/offline_sync_versions.sql`,
`offline_sync_receipts.sql` and `training_incarnations.sql`; CI runs all three.
The accompanying
Python concurrency and migration-upgrade probes test real parallel transactions
and an existing collection larger than the default history allowance.
