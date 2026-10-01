-- record_training_history and delete_training_history are internal steps of
-- apply_sync_operation (trainingHistoryInsert/trainingHistoryDelete). That
-- RPC is security definer, so it calls them with its owner's rights and needs
-- no caller grant. Clients write training history only through it since
-- 20260920101000; the direct client calls were removed. A direct call skipped
-- the operation receipt, so `authenticated` loses EXECUTE. `service_role`
-- keeps it, like the other receipt-internal helpers (apply_recipe_mutation,
-- apply_training_plan_mutation).
revoke execute on function public.record_training_history(uuid, timestamptz, jsonb)
  from public, anon, authenticated;
revoke execute on function public.delete_training_history(uuid)
  from public, anon, authenticated;
grant execute on function public.record_training_history(uuid, timestamptz, jsonb)
  to service_role;
grant execute on function public.delete_training_history(uuid)
  to service_role;
