-- Eatova — Byte-Deckel fuer Chat-Nachrichten (Security-Review 2026-08-11,
-- Finding 2, CWE-400: "Rejected oversized coach prompts are stored and
-- replayed").
--
-- BEFUND: chat_messages.content (20260517100000_coach_chat.sql) ist ein
-- text ohne jede Byte-Beschraenkung. Der too_long-Refusal-Pfad der Edge
-- Function coach-chat speicherte die VOLLE abgelehnte Nachricht via
-- service_role — ein authentifizierter Caller konnte pro Request bis knapp
-- unter die 6,25-MB-Grenze (MAX_CONTENT_LENGTH) persistieren. loadHistory
-- begrenzt nur ROWS (HISTORY_LIMIT 10), nicht Bytes: jede Folgefrage lud
-- diese Rows komplett und schickte sie im OpenRouter-Request mit —
-- Amplifikation von Storage, Memory, Traffic und Provider-Kosten.
--
-- Inhalt (haertend + idempotent):
--   1) Bestehende oversized Rows kappen — sonst schluege der CHECK unten
--      beim Anlegen fehl (ADD CONSTRAINT validiert den Bestand).
--   2) CHECK-Constraint auf octet_length(content).
--
-- Der Handler lehnt Groessenverletzungen seit demselben Fix VOR jeder
-- Persistenz mit 413 ab (message_too_long) und kappt geladene History
-- zusaetzlich pro Row + per Aggregat-Budget (handler.ts) — der CHECK hier
-- ist die letzte Verteidigungslinie direkt an der Tabelle, gegen jeden
-- kuenftigen Schreibpfad.
--
-- LIMIT-WAHL 16384 Bytes: die laengsten LEGITIMEN Inhalte, die die Function
-- schreibt, sind (a) User-Messages — seit dem 413-Guard maximal 1000
-- UTF-16-Zeichen bzw. 4000 Bytes (MAX_INPUT_BYTES) — und (b)
-- Assistant-Antworten mit max_tokens 600 (wenige KB, auch multi-byte);
-- Refusal-Texte (refusalForReason) sind einstellige Hundert Bytes. 16384
-- laesst also >4x Puffer zum groessten legitimen Inhalt und ist trotzdem
-- drei Groessenordnungen unter dem bisherigen 6,25-MB-Fenster.

-- ---------------------------------------------------------------------------
-- 1) Bestands-Quarantaene: oversized Rows auf die History-Row-Grenze des
--    Handlers kappen (HISTORY_ROW_MAX_CHARS = 4000 Zeichen; selbst bei
--    4-Byte-Zeichen maximal 16000 Bytes und damit sicher unter dem CHECK).
--    left() zaehlt Zeichen, der CHECK Bytes — deshalb die Zeichen-Grenze,
--    nicht 16384.
-- ---------------------------------------------------------------------------
update public.chat_messages
   set content = left(content, 4000)
 where octet_length(content) > 16384;

-- ---------------------------------------------------------------------------
-- 2) CHECK-Constraint. drop/add statt add-if-not-exists (gibt es in Postgres
--    nicht) — Re-Runs bleiben damit idempotent.
-- ---------------------------------------------------------------------------
alter table public.chat_messages
  drop constraint if exists chat_messages_content_octets_max;

alter table public.chat_messages
  add constraint chat_messages_content_octets_max
  check (octet_length(content) <= 16384);
