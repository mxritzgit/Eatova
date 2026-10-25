"""Two concurrent alias signups of one mailbox in the caller's disposable database."""
import concurrent.futures
import json
import os
import subprocess
import time
import uuid

FIRST = "email_alias_race_first"
SECOND = "email_alias_race_second"


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def run_tests(sql):
    """sql executes psql input and returns stdout; caller owns the disposable DB."""
    users = [str(uuid.uuid4()), str(uuid.uuid4())]
    # One Gmail mailbox in two spellings, both unconfirmed email signups.
    addresses = ["alias.race@gmail.com", "aliasrace+second@gmail.com"]
    # Holds the first insert open until the second session waits on the
    # advisory lock (or 10 s pass), then commits.
    first_signup = (
        "set application_name=" + literal(FIRST) + ";"
        "create function pg_temp.await_second() returns boolean language plpgsql as $$"
        "declare deadline timestamptz := clock_timestamp() + interval '10 seconds';"
        "begin loop perform pg_stat_clear_snapshot();"
        " if exists (select 1 from pg_stat_activity where application_name=" + literal(SECOND) +
        " and wait_event_type='Lock' and wait_event='advisory') then return true; end if;"
        " if clock_timestamp() > deadline then return false; end if;"
        " perform pg_sleep(0.05); end loop; end $$;"
        "begin;"
        "insert into auth.users(id,email) values(" + literal(users[0]) + "," + literal(addresses[0]) + ");"
        "select pg_temp.await_second();"
        "commit;")
    second_signup = (
        "set application_name=" + literal(SECOND) + ";"
        "create function pg_temp.try_signup() returns text language plpgsql as $$"
        "begin insert into auth.users(id,email) values(" + literal(users[1]) + "," + literal(addresses[1]) + ");"
        " return 'inserted'; exception when others then return sqlstate; end $$;"
        "select pg_temp.try_signup();")
    first_is_waiting = ("select count(*) from pg_stat_activity where application_name=" +
                        literal(FIRST) + " and wait_event='PgSleep'")
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(sql, first_signup)
            deadline = time.monotonic() + 10
            while sql(first_is_waiting).strip() == "0":
                assert not first.done(), "first signup ended early: " + repr(first.result())
                assert time.monotonic() < deadline, "first signup never held its insert open"
                time.sleep(0.05)
            second = pool.submit(sql, second_signup)
            second_waited = first.result().strip()
            outcome = second.result().strip()
        assert outcome == "P0001", "concurrent alias signup was not rejected: " + outcome
        assert second_waited == "t", "second signup did not wait for the first"
        rows = sql("select string_agg(id::text, ',') from auth.users where id in (" +
                   ",".join(literal(u) for u in users) + ")").strip()
        assert rows == users[0], "expected only the first account, got " + rows
        return {"concurrent_alias_signups": 2, "second_waited_for_lock": True,
                "second_sqlstate": outcome, "accounts_left": 1}
    finally:
        sql("delete from auth.users where id in (" + ",".join(literal(u) for u in users) + ")")


if __name__ == "__main__":
    # Never accept an arbitrary production connection from inherited variables.
    if os.environ.get("PGHOST") not in {"localhost", "127.0.0.1", "::1"} or os.environ.get("PGDATABASE") != "rls":
        raise SystemExit("Only the explicit local disposable RLS database is supported.")

    def local_sql(statement):
        result = subprocess.run(["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
                                input=statement, capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    print(json.dumps(run_tests(local_sql)))
