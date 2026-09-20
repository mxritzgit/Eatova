"""Real concurrent receipt/CAS races in a caller-owned disposable database."""
import concurrent.futures
import json
import os
import subprocess
import uuid

from training_incarnation_concurrency import run_tests as run_training_tests


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def recipe(slug, title):
    return dict(slug=slug, title=title, description="", portion="", ingredients="",
                preparation="", image_asset="", calories_kcal=100, protein_g=10,
                carbs_g=10, fat_g=2, estimated_g=100, categories=[],
                structured_ingredients=[], batch_servings=1)


def run_tests(sql):
    users = [str(uuid.uuid4()), str(uuid.uuid4())]
    sql("insert into auth.users(id) values " + ",".join("(" + literal(u) + ")" for u in users))

    def as_user(user, statement):
        return sql("set role authenticated; set request.jwt.claims=" +
                   literal(json.dumps({"sub": user, "role": "authenticated"})) + ";" + statement)

    def write(user, operation, title, revision):
        payload = json.dumps({"recipe": recipe("user_race", title), "expected_revision": revision})
        return json.loads(as_user(user, "select public.apply_sync_operation(" + literal(operation) +
                                  ",'recipeUpsert','user_race'," + literal(payload) + ")"))

    try:
        first_op = str(uuid.uuid4())
        first = write(users[0], first_op, "Initial", 0)
        base = first["result"]["recipe_mutation"]["current_revision"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(write, users[0], str(uuid.uuid4()), title, base)
                       for title in ["Device A draft", "Device B draft"]]
            replies = [future.result() for future in futures]
        outcomes = sorted(reply["result"]["recipe_mutation"]["outcome"] for reply in replies)
        assert outcomes == ["applied", "conflictSaved"], outcomes
        titles = json.loads(as_user(users[0],
            "select jsonb_agg(title order by title) from public.user_recipes"))
        assert titles == ["Device A draft", "Device B draft"], titles
        assert write(users[0], first_op, "Initial", 0)["result"] == first["result"]
        titles_after = json.loads(as_user(users[0],
            "select jsonb_agg(title order by title) from public.user_recipes"))
        assert titles_after == titles, "Late repeat rewound a committed device edit"

        same_op = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            replies = list(pool.map(lambda _: write(users[1], same_op, "One effect", 0), range(12)))
        assert all(reply == replies[0] for reply in replies), "Concurrent retries returned different receipts"
        assert as_user(users[1], "select count(*) from public.user_recipes").strip() == "1"
        assert sql("select count(*) from public.sync_operation_receipts where user_id=" + literal(users[1])).strip() == "1"
        # The same UUID belongs to an account, not a globally guessable namespace.
        other = write(users[1], first_op, "Other owner's draft", 1)
        assert other["operation_id"] == first_op and other != first
        assert as_user(users[0], "select count(*) from public.user_recipes where title='Other owner''s draft'").strip() == "0"
        global_id = str(uuid.uuid4())

        def same_global_identity(user):
            row = dict(id=global_id, logged_at="2026-09-18T12:00:00Z", local_day="2026-09-18",
                       forced_slot="lunch", meal_name="Race", calories_kcal=100,
                       estimated_g=100, protein_g=10, carbs_g=10, fat_g=2, payload={})
            payload = json.dumps({"row": row, "track_day": False})
            try:
                as_user(user, "select public.apply_sync_operation(" + literal(str(uuid.uuid4())) +
                        ",'mealInsert'," + literal(global_id) + "," + literal(payload) + ")")
                return "applied"
            except Exception as error:
                assert "EX_OWNER_REQUIRED" in str(error), str(error)
                return "ownerRejected"

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            global_outcomes = sorted(pool.map(same_global_identity, users))
        assert global_outcomes == ["applied", "ownerRejected"], global_outcomes
        assert sql("select sum(meals_logged) from public.lifetime_stats where user_id in (" +
                   ",".join(literal(u) for u in users) + ")").strip() == "1"
        for _ in range(6):
            plan_id = str(uuid.uuid4())
            conversion = ("select public.eat_planned_meal(rlstest.meal_plan(" + literal(plan_id) +
                          ")||jsonb_build_object('eaten_at',now()),rlstest.plan_meal(" + literal(plan_id) + "),true)")
            deletion = ("select public.apply_sync_operation(" + literal(str(uuid.uuid4())) +
                        ",'mealDelete'," + literal(plan_id) + ",'{}')")
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                writes = [pool.submit(as_user, users[0], statement) for statement in [conversion, deletion]]
                for write_result in writes:
                    write_result.result()
            assert as_user(users[0], "select count(*) from public.logged_meals where id=" + literal(plan_id)).strip() == "0", "Conversion raced past diary deletion"
        return {"device_race": outcomes, "same_operation_concurrent_requests": 12,
                "same_operation_effects": 1, "late_retry_preserved_newer_writes": True,
                "cross_user_operation_namespace": True, "cross_user_global_uuid_race": global_outcomes,
                "legacy_conversion_vs_diary_delete_races": 6,
                "training_incarnations": run_training_tests(sql)}
    finally:
        sql("delete from auth.users where id in (" + ",".join(literal(u) for u in users) + ")")


if __name__ == "__main__":
    if os.environ.get("PGHOST") not in {"localhost", "127.0.0.1", "::1"} or os.environ.get("PGDATABASE") != "rls":
        raise SystemExit("Only the explicit local disposable RLS database is supported.")

    def local_sql(statement):
        result = subprocess.run(["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
                                input=statement, capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    print(json.dumps(run_tests(local_sql)))
