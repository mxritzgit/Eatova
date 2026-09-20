"""Replays the staged recipe upgrade over a valid collection larger than 64 MiB."""
import json
import os
from pathlib import Path
import subprocess
import uuid


ROOT = Path(__file__).resolve().parents[2]


def run_tests(sql, in_database):
    database = "rls_sync_upgrade_" + uuid.uuid4().hex[:10]
    owner = "74000000-0000-4000-8000-000000000001"
    sql("create database " + database)
    try:
        def execute(value):
            return in_database(database, value)

        execute((ROOT / "test/migrations/pg_bootstrap.sql").read_text(encoding="utf-8"))
        migrations = sorted((ROOT / "supabase/migrations").glob("*.sql"))
        for migration in migrations:
            if migration.name >= "20260920100000":
                continue
            execute(migration.read_text(encoding="utf-8"))
        execute("insert into auth.users(id) values ('" + owner + "');"
                "insert into public.user_recipes(user_id,slug,title,ingredients,preparation) "
                "select '" + owner + "','user_upgrade_'||n,'Legacy recipe '||n,repeat('i',20000),repeat('p',20000) "
                "from generate_series(1,1800) n")
        training_plan = sql("select rlstest.training_plan()").strip().replace("'", "''")
        execute("insert into public.training_plans(user_id,id,plan,exercise_ids) values('" + owner +
                "','coach_upgrade','" + training_plan + "','[[\"squat\",\"plank\"]]')")
        execute((ROOT / "supabase/migrations/20260920100000_offline_sync_versions.sql").read_text(encoding="utf-8"))
        execute("insert into public.sync_entity_deletions(user_id,family,entity_id) values('" + owner +
                "','training_plan','coach_deleted_upgrade')")
        for migration in migrations:
            if migration.name > "20260920100000_offline_sync_versions.sql":
                execute(migration.read_text(encoding="utf-8"))
        assert execute("select count(*) from public.training_plan_heads where user_id='" + owner + "'").strip() == "2"
        assert execute("select source_id from public.training_plans where user_id='" + owner + "'").strip() == "upgrade"
        assert execute("select incarnation=0 and deleted from public.training_plan_heads where user_id='" + owner +
                       "' and source_id='deleted_upgrade'").strip() == "t"
        state = json.loads(execute("select to_jsonb(h) from public.recipe_sync_heads h where user_id='" + owner + "'"))
        assert state["history_bytes"] > 67108864
        assert state["history_budget"] >= state["history_bytes"] + 67108864
        assert execute("select count(*) from public.recipe_revisions where user_id='" + owner + "'").strip() == "1800"
        change = ("set role authenticated; set request.jwt.claims='{\"sub\":\"" + owner + "\"}';"
                  "update public.user_recipes set title='New version' where slug='user_upgrade_1';")
        # This is the actual old failure: successful migration with a fixed
        # allowance makes every otherwise valid following update fail.
        execute("update public.recipe_sync_heads set history_budget=67108864 where user_id='" + owner + "'")
        try:
            execute(change)
        except Exception as error:
            assert "EX_RECIPE_HISTORY_CAPACITY" in str(error)
        else:
            raise AssertionError("Fixed-budget negative control was not detected")
        execute("update public.recipe_sync_heads set history_budget=" + str(state["history_budget"]) + " where user_id='" + owner + "'")
        execute(change)
        execute("set role authenticated; set request.jwt.claims='{\"sub\":\"" + owner + "\"}';"
                "delete from public.user_recipes where slug='user_upgrade_2'")
        assert execute("select title from public.user_recipes where user_id='" + owner + "' and slug='user_upgrade_1'").strip() == "New version"
        assert execute("select count(*) from public.recipe_revisions where user_id='" + owner + "'").strip() == "1802"
        return {"legacy_recipes": 1800, "legacy_bytes": state["history_bytes"],
                "history_budget": state["history_budget"], "post_upgrade_edit_and_delete": "PASS",
                "fixed_budget_negative_control": "detected", "legacy_training_heads_backfilled": 2}
    finally:
        sql("drop database " + database + " with (force)")


if __name__ == "__main__":
    if os.environ.get("PGHOST") not in {"localhost", "127.0.0.1", "::1"} or os.environ.get("PGDATABASE") != "rls":
        raise SystemExit("Only the explicit local disposable RLS database is supported.")

    def execute(statement, database=None):
        args = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
        if database is not None:
            args.extend(["-d", database])
        completed = subprocess.run(args, input=statement, capture_output=True, text=True, timeout=90)
        if completed.returncode:
            raise RuntimeError(completed.stderr)
        return completed.stdout

    print(json.dumps(run_tests(execute, lambda database, statement: execute(statement, database))))
