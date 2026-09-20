"""Concurrent training generation fences in the caller's disposable database."""
import concurrent.futures
import json
import uuid


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def run_tests(sql):
    user = str(uuid.uuid4())
    sql("insert into auth.users(id) values(" + literal(user) + ")")

    def as_user(statement):
        return sql("set role authenticated; set request.jwt.claims=" +
                   literal(json.dumps({"sub": user, "role": "authenticated"})) + ";" + statement)

    def upsert(source, incarnation, title, adoption=False, operation=None):
        payload = ("jsonb_build_object('row',jsonb_build_object('id'," + literal("coach_" + source) +
                   ",'source_id'," + literal(source) + ",'incarnation'," + str(incarnation) +
                   ",'plan',jsonb_set(rlstest.training_plan(),'{title}',to_jsonb(" + literal(title) +
                   "::text)),'exercise_ids','[[\"squat\",\"plank\"]]'::jsonb),'adoption'," +
                   ("true" if adoption else "false") + ")")
        return json.loads(as_user("select public.apply_sync_operation(" + literal(operation or str(uuid.uuid4())) +
                                  ",'trainingPlanUpsert'," + literal("coach_" + source) + "," + payload + ",2)"))

    def delete(source, incarnation):
        return as_user("select public.apply_sync_operation(" + literal(str(uuid.uuid4())) +
                       ",'trainingPlanDelete'," + literal("coach_" + source) + "," +
                       literal(json.dumps({"incarnation": incarnation})) + ",2)")

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            replies = list(pool.map(lambda title: upsert("shared", 0, title, True), ["Device A", "Device B"]))
        assert all(reply["result"]["training_mutation"]["outcome"] == "applied" for reply in replies)
        assert as_user("select count(*) from public.training_plans where id='coach_shared'").strip() == "1"
        delete("shared", 0)
        same_op = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            replies = list(pool.map(lambda _: upsert("shared", 1, "Explicit new", True, same_op), range(8)))
        assert all(reply == replies[0] for reply in replies), "Concurrent adoption retries changed their receipt"
        assert as_user("select incarnation from public.training_plans where id='coach_shared'").strip() == "1"
        assert sql("select count(*) from public.sync_operation_receipts where user_id=" + literal(user) +
                   " and operation_id=" + literal(same_op)).strip() == "1"
        for index in range(6):
            source = "race_" + str(index)
            upsert(source, 0, "Initial", True)
            delete(source, 0)
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                jobs = [pool.submit(upsert, source, 1, "New A", True),
                        pool.submit(upsert, source, 1, "New B", True),
                        pool.submit(delete, source, 0),
                        pool.submit(upsert, source, 0, "Delayed first edit")]
                for job in jobs:
                    job.result()
            result = json.loads(as_user("select public.load_training_plan_head(" + literal(source) + ")"))
            assert result["incarnation"] == 1 and not result["deleted"], result
            assert result["plan"]["plan"]["title"] in {"New A", "New B"}, result
            assert as_user("select count(*) from public.training_plans where id=" + literal("coach_" + source)).strip() == "1"
        return {"simultaneous_proposal_dedup": True, "same_adoption_retries": 8,
                "new_adoptions_vs_old_first_upsert_and_delete_races": 6}
    finally:
        sql("delete from auth.users where id=" + literal(user))
