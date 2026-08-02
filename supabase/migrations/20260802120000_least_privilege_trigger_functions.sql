-- Least-Privilege-Kosmetik (Audit 2026-08-02). Rein additiv + idempotent.
--
-- 1) handle_new_user_stats() und set_updated_at() trugen als einzige
--    Funktionen im Schema residual PUBLIC-EXECUTE (leerer Grantee "=X/…" im
--    ACL). Trigger-Funktionen sind via PostgREST-RPC nicht aufrufbar
--    (Rueckgabetyp trigger) — praktisch harmlos, aber inkonsistent zur
--    expliziten PUBLIC/anon-Revoke-Linie aller uebrigen Funktionen.
--    EXECUTE wird bei Triggern nur zur CREATE-TRIGGER-Zeit geprueft;
--    bestehende Trigger feuern nach dem Revoke unveraendert.
-- 2) set_updated_at() war die einzige Funktion ohne gepinnten search_path
--    (Supabase-Linter: function_search_path_mutable). Body nutzt nur now()
--    (pg_catalog wird implizit immer zuerst durchsucht) — Pinning auf public
--    ist verhaltensneutral. handle_new_user_stats hat public bereits gepinnt
--    und qualifiziert public.lifetime_stats ohnehin explizit.

revoke execute on function public.handle_new_user_stats() from public, anon, authenticated;
revoke execute on function public.set_updated_at()        from public, anon, authenticated;
grant execute on function public.handle_new_user_stats() to service_role;
grant execute on function public.set_updated_at()        to service_role;

alter function public.set_updated_at() set search_path = public;
