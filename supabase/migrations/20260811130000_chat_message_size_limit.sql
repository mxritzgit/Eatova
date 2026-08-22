-- Byte cap for chat messages (Security review 2026-08-11, Finding 2,
-- CWE-400: rejected oversized coach prompts were stored and replayed).
--
-- chat_messages.content had no byte limit, so the too_long refusal path
-- persisted the full rejected message via service_role, and loadHistory
-- (which limits rows, not bytes) replayed it to OpenRouter on every follow-up.
--
-- Contents (hardening, idempotent):
--   1) Truncate existing oversized rows, or ADD CONSTRAINT would fail.
--   2) CHECK constraint on octet_length(content).
--
-- The handler already rejects oversized input with 413 before persisting;
-- this CHECK is the last line of defence for any future write path.
--
-- Why 16384 bytes: the longest legitimate content is a user message (1000
-- characters / 4000 bytes) or an assistant reply at max_tokens 600 — over 4x
-- headroom, and three orders of magnitude below the old 6.25 MB window.

-- ---------------------------------------------------------------------------
-- 1) Quarantine existing rows at the handler's history row limit
--    (HISTORY_ROW_MAX_CHARS = 4000 chars; at most 16000 bytes even with
--    4-byte characters). left() counts characters, the CHECK counts bytes,
--    hence the character limit rather than 16384.
-- ---------------------------------------------------------------------------
update public.chat_messages
   set content = left(content, 4000)
 where octet_length(content) > 16384;

-- ---------------------------------------------------------------------------
-- 2) CHECK constraint. drop/add instead of add-if-not-exists (which Postgres
--    lacks), keeping re-runs idempotent.
-- ---------------------------------------------------------------------------
alter table public.chat_messages
  drop constraint if exists chat_messages_content_octets_max;

alter table public.chat_messages
  add constraint chat_messages_content_octets_max
  check (octet_length(content) <= 16384);
