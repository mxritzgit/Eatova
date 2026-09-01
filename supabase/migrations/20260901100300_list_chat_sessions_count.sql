-- Performance audit 2026-09-01, A8 — public.list_chat_sessions() counted the
-- messages of a session with a CORRELATED subquery, so the count was a SubPlan
-- the executor re-ran once per session row: N conversations meant N index
-- lookups, N bitmap builds and N aggregate start-ups, although the answer for
-- all of them lies in ONE pass over the same index. The cost grew with the
-- number of conversations, on the one call the coach tab makes every time it
-- opens (CoachChatService.loadSessions).
--
-- Replaced by a SINGLE grouped aggregate, left-joined onto the session list.
-- Nothing a caller can observe changes; the properties that had to stay
-- identical are named below, because each is a way this rewrite could have
-- broken silently.
--
-- ---------------------------------------------------------------------------
-- 1) WIRE SHAPE. lib/src/models/chat_session.dart (ChatSession.fromRow) reads
--    id, title, created_at, last_message_at and message_count out of the rows.
--    The `returns table` clause is copied unchanged, so names, types and order
--    are fixed by the DECLARATION, not by the body — the body only fills the
--    five columns positionally, in the same order, from the same source
--    columns, under the same `order by last_message_at desc`.
--
-- 2) EMPTY SESSIONS. A correlated count(*) yields 0 for a session that holds
--    no messages; an inner join would DROP that row instead, and a freshly
--    created conversation would vanish from the user's list before the first
--    answer arrives (ChatSession.isEmpty is built on exactly this 0). Hence a
--    LEFT JOIN onto the aggregate plus `coalesce(..., 0)`. The same path
--    covers a session holding only 'system' rows: the role filter sits inside
--    the aggregate, so such a session has no counterpart there and coalesces
--    to 0 — which is what the old subquery returned for it too.
--    The old body's own coalesce was dead code: a scalar subquery over count()
--    always returns a row. Here the coalesce carries the whole zero case, so
--    it is load-bearing for the first time.
--
-- 3) OWNERSHIP. `security definer` switches RLS on chat_sessions off for this
--    function, so `where s.user_id = auth.uid()` is the ONLY thing keeping it
--    to the caller's own rows; it is kept verbatim, and the aggregate is
--    bounded by that same set. Deliberately NOT bounded by
--    chat_messages.user_id: the old count matched on session_id alone, and
--    adding a user_id condition would silently change the number for any row
--    where the two ever disagreed.
--
-- 4) WHY `= any (array(...))` AND NOT A PLAIN JOIN. chat_messages is a
--    multi-tenant table, so the obvious `join chat_sessions … where user_id =
--    auth.uid()` leaves the planner a choice between "index-scan the caller's
--    sessions" and "seq-scan EVERY user's messages, then hash-join". Measured
--    on PostgreSQL 16 (301 users, 9607 sessions, 46171 messages; the caller
--    owning 305 sessions and 776 counted messages) it chose the seq scan:
--    42953 rows read for the 776 that mattered, 5.2 ms against the old form's
--    0.87 ms — a REGRESSION, and one that grows with every OTHER user in the
--    table. The uncorrelated `array(select …)` is an InitPlan evaluated once
--    and turns the message read into a single index scan with `session_id =
--    ANY ($0)`: bounded by the CALLER'S own sessions exactly as the old
--    subquery was, but still ending in one aggregate instead of 305. Same
--    measurement: 0.52 ms.
--    The gap widens with the number of conversations, which is the finding:
--    a user at 3000 sessions goes from 12.6 ms (3000 SubPlan loops, 2770 heap
--    blocks touched) to 6.9 ms (one GroupAggregate, 106 heap blocks).
--
-- 5) INDEX. No new index. chat_messages_session_created_idx (session_id,
--    created_at) from 20260517170000 already LEADS with session_id and serves
--    the ScalarArrayOp scan exactly as it served the subquery — the plan above
--    is a bitmap index scan on it. A separate (session_id) index would be a
--    pure duplicate of that prefix and would only cost write time; a wider one
--    would not help either, because the role filter has always needed the heap
--    tuple, before and after.
--
-- Idempotent: `create or replace` plus the grants re-asserted. Replays from an
-- empty database (this file sorts after 20260517170000, which creates the
-- function, and after 20260609120000, which pins its ACL) and re-applies
-- unchanged on the live one.
-- ---------------------------------------------------------------------------

create or replace function public.list_chat_sessions()
returns table (
  id              uuid,
  title           text,
  created_at      timestamptz,
  last_message_at timestamptz,
  message_count   integer
)
language sql
security definer
set search_path = public
as $$
  with counts as (
    -- The counts for ALL of the caller's sessions in one grouped pass. No
    -- outer reference, so unlike the old SubPlan there is nothing the executor
    -- could re-run per result row. An empty session set yields an empty array
    -- and therefore no counts at all, which the left join below turns into the
    -- correct empty result rather than an error.
    select m.session_id as sid, count(*)::integer as msg_count
      from public.chat_messages m
     where m.session_id = any (array(
             select o.id
               from public.chat_sessions o
              where o.user_id = auth.uid()))
       and m.role in ('user', 'assistant')
     group by m.session_id
  )
  select s.id, s.title, s.created_at, s.last_message_at,
         coalesce(c.msg_count, 0)
    from public.chat_sessions s
    left join counts c on c.sid = s.id
   where s.user_id = auth.uid()
   order by s.last_message_at desc;
$$;

comment on function public.list_chat_sessions() is
  'The calling user''s chat sessions, newest activity first, each with the '
  'number of its user/assistant messages. The count comes from one grouped '
  'aggregate LEFT JOINed onto the session list, so a session without messages '
  'still appears with 0. Performance audit 2026-09-01, A8.';

-- `create or replace` keeps the existing ACL, but 20260609120000 pins it
-- explicitly for exactly this reason — repeat it here so the privilege state
-- is readable from the file that last touched the function.
revoke execute on function public.list_chat_sessions() from public, anon;
grant execute on function public.list_chat_sessions() to authenticated, service_role;
