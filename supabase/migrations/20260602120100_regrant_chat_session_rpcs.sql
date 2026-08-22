-- Re-grants the chat session RPCs to authenticated: 20260517220000 revoked
-- execute on all public functions after these RPCs were created, so the client
-- hit 42501 permission denied. They are security-definer and user-scoped
-- (auth.uid()), hence safe for authenticated. touch_chat_session stays
-- service_role-only. Idempotent.

grant execute on function public.list_chat_sessions()            to authenticated;
grant execute on function public.ensure_default_chat_session(uuid) to authenticated;
grant execute on function public.create_chat_session(text)         to authenticated;
grant execute on function public.rename_chat_session(uuid, text)   to authenticated;
grant execute on function public.delete_chat_session(uuid)         to authenticated;
