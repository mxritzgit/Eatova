"""Bounded synthetic races, only in the disposable CI/local RLS database."""
import concurrent.futures
import json
import os
import subprocess
import uuid


def run_tests(sql):
    """sql executes psql input and returns stdout; caller owns the disposable DB."""
    assert sql("select count(*) from public.ai_provider_daily_usage").strip() == "0"
    assert sql("select count(*) from public.ai_provider_user_usage").strip() == "0"
    users = [str(uuid.uuid4()) for _ in range(20)]
    sql("insert into auth.users(id) values " + ",".join("('" + user + "')" for user in users))
    try:
        def claim(user):
            return json.loads(sql("set role service_role; select public.reserve_ai_provider_call('" + user + "','coach_answer')"))

        sql("update public.ai_provider_limits set daily_call_limit=7,daily_user_limit=100")
        with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
            outcomes = list(pool.map(claim, users))
        granted = sum(result.get("allowed") is True for result in outcomes)
        assert granted == 7, f"global race: expected 7 grants, got {granted}"
        assert sum(result.get("reason") == "budget_exhausted" for result in outcomes) == 13
        assert sql("select sum(calls) from public.ai_provider_daily_usage").strip() == "7"
        assert sql("select sum(calls) from public.ai_provider_user_usage").strip() == "7"

        sql("truncate public.ai_provider_daily_usage,public.ai_provider_user_usage; update public.ai_provider_limits set daily_call_limit=100,daily_user_limit=4")
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            outcomes = list(pool.map(claim, [users[0]] * 12))
        granted = sum(result.get("allowed") is True for result in outcomes)
        assert granted == 4, f"account race: expected 4 grants, got {granted}"
        assert sql("select sum(calls) from public.ai_provider_daily_usage").strip() == "4"
        assert sql("select sum(calls) from public.ai_provider_user_usage").strip() == "4"
        return {"global_accounts": 20, "global_granted": 7, "global_denied": 13,
                "same_account_requests": 12, "same_account_granted": 4, "same_account_denied": 8}
    finally:
        sql("delete from auth.users where id in (" + ",".join("'" + user + "'" for user in users) + ");"
            "truncate public.ai_provider_daily_usage,public.ai_provider_user_usage;"
            "update public.ai_provider_limits set daily_call_limit=default,daily_user_limit=default")


if __name__ == "__main__":
    # Never accept an arbitrary production connection from inherited variables.
    if os.environ.get("PGHOST") not in {"localhost", "127.0.0.1", "::1"} or os.environ.get("PGDATABASE") != "rls":
        raise SystemExit("Only the explicit local disposable RLS database is supported.")

    def local_sql(statement):
        result = subprocess.run(["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
                                input=statement, capture_output=True, text=True, timeout=30, check=True)
        return result.stdout

    print(json.dumps(run_tests(local_sql)))
