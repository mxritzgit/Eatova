-- Users can export their own technical daily AI usage. Reading these counters
-- grants no quota writes or visibility of other users, global usage or limits.
create policy ai_provider_user_usage_select_own
  on public.ai_provider_user_usage
  for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.ai_provider_user_usage to authenticated;
