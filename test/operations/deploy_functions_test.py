"""Offline tests for the Edge Function deploy tooling and its workflow.

No credentials, sockets or live data: HTTP goes through fakes, source trees
are temporary directories, and the workflow is checked as text.
"""

import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('deploy_functions', ROOT / 'scripts/operations/deploy_functions.py')
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)
WORKFLOW = ROOT / '.github/workflows/deploy-functions.yml'
REF = 'abcdefghijklmnopqrst'
TOKEN = 'test-management-token'
ANON = 'synthetic-anon-key'
SHA_A = 'a' * 40
SHA_B = 'b' * 40


def write(base, relative, text, newline='\n'):
    path = Path(base) / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.replace('\n', newline).encode('utf-8'))
    return path


def function_tree(base):
    """A checkout with two functions sharing a module, like the real layout."""
    write(base, 'supabase/functions/_shared/http.ts', "export const A = 1;\n")
    write(base, 'supabase/functions/_shared/types.ts', "import { A } from './http.ts';\nexport type T = typeof A;\n")
    write(base, 'supabase/functions/_shared/http_test.ts', "import { A } from './http.ts';\n")
    write(base, 'supabase/functions/coach-chat/index.ts', "import { handleRequest } from './handler.ts';\nDeno.serve(handleRequest);\n")
    write(base, 'supabase/functions/coach-chat/handler.ts', (
        "// import { nothing } from './ghost.ts';\n"
        "import type { T } from '../_shared/types.ts';\n"
        "import {\n  A,\n} from \"../_shared/http.ts\";\n"
        "export async function handleRequest(): Promise<Response> { return new Response(String(A)); }\n"))
    write(base, 'supabase/functions/search-key/index.ts', "import { A } from '../_shared/http.ts';\nDeno.serve(() => new Response(String(A)));\n")
    return Path(base)


class FakeResponse:
    def __init__(self, status, body):
        self.status = status
        self.body = body

    def read(self, limit=-1):
        return self.body if limit < 0 else self.body[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def http_error(url, status, body=b''):
    return urllib.error.HTTPError(url, status, 'error', {}, io.BytesIO(body))


class SlugTest(unittest.TestCase):
    def test_all_and_lists_are_validated_against_the_checkout_and_the_probe_table(self):
        available = ['analyze-meal', 'coach-chat', 'recipe-import', 'search-key']
        self.assertEqual(deploy.parse_slugs('all', available), available)
        self.assertEqual(deploy.parse_slugs(' coach-chat, search-key ,coach-chat,', available),
                         ['coach-chat', 'search-key'])
        for raw, reason in [('', 'no_functions_selected'), (',', 'no_functions_selected'),
                            ('Coach-Chat', 'invalid_slug'), ('coach-chat;rm', 'invalid_slug'),
                            ('../coach-chat', 'invalid_slug'), ('_shared', 'invalid_slug'),
                            ('ghost', 'unknown_function:ghost')]:
            with self.assertRaises(deploy.DeployError, msg=raw) as caught:
                deploy.parse_slugs(raw, available)
            self.assertEqual(str(caught.exception), reason)
        with self.assertRaises(deploy.DeployError) as caught:
            deploy.parse_slugs('all', available + ['new-function'])
        self.assertEqual(str(caught.exception), 'no_boot_probe_defined:new-function')

    def test_every_real_function_has_a_boot_probe_with_codes_its_handler_returns(self):
        self.assertEqual(sorted(deploy.PROBES), deploy.available_functions(ROOT))
        for slug, (method, codes) in deploy.PROBES.items():
            source = '\n'.join((ROOT / 'supabase/functions' / path).read_text(encoding='utf-8')
                               for path in deploy.import_graph(ROOT / 'supabase/functions', slug))
            self.assertIn(method, ('GET', 'POST'))
            for code in codes:
                self.assertRegex(source, r"""['"]""" + re.escape(code) + r"""['"]""", f'{slug}: {code}')


class VerifyJwtGuardTest(unittest.TestCase):
    def test_a_config_that_disables_verify_jwt_is_refused(self):
        with tempfile.TemporaryDirectory() as base:
            deploy.assert_verify_jwt_kept(base)
            write(base, 'supabase/config.toml', '[functions.coach-chat]\nverify_jwt = true\n')
            deploy.assert_verify_jwt_kept(base)
            write(base, 'supabase/config.toml', '[functions.search-key]\n  verify_jwt   =   false # temporary\n')
            with self.assertRaises(deploy.DeployError) as caught:
                deploy.assert_verify_jwt_kept(base)
            self.assertEqual(str(caught.exception), 'verify_jwt_disabled_in_config')

    def test_the_repository_keeps_the_cli_default(self):
        deploy.assert_verify_jwt_kept(ROOT)


class ImportGraphTest(unittest.TestCase):
    def test_import_forms_and_comments(self):
        text = (
            "import { a, type B } from './a.ts';\n"
            "import type { C } from \"./c.ts\";\n"
            "export * from './d.ts';\nexport type { E } from './e.ts';\n"
            "import './side.ts';\nconst f = await import('./f.ts');\n"
            "/* import { g } from './g.ts'; */\n// import { h } from './h.ts';\n"
            "import {\n  i,\n  j,\n} from '../i.ts';\nimport x from 'jsr:@std/x';\n")
        self.assertEqual(sorted(deploy.module_specifiers(text)), sorted([
            ('./a.ts', False), ('./c.ts', True), ('./d.ts', False), ('./e.ts', True),
            ('./side.ts', False), ('./f.ts', False), ('../i.ts', False), ('jsr:@std/x', False)]))

    def test_graph_follows_relative_imports_and_upgrades_type_only_modules(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(base)
            graph = deploy.import_graph(tree / 'supabase/functions', 'coach-chat')
            self.assertEqual(list(graph), ['_shared/http.ts', '_shared/types.ts',
                                           'coach-chat/handler.ts', 'coach-chat/index.ts'])
            self.assertTrue(graph['_shared/types.ts']['type_only'])
            # Reached by type and by value: a value module, whatever came first.
            self.assertFalse(graph['_shared/http.ts']['type_only'])
            self.assertNotIn('_shared/http_test.ts', graph)

    def test_unresolved_and_escaping_imports_are_refused(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(base)
            write(tree, 'supabase/functions/search-key/index.ts', "import { x } from './missing.ts';\n")
            with self.assertRaises(deploy.DeployError) as caught:
                deploy.import_graph(tree / 'supabase/functions', 'search-key')
            self.assertEqual(str(caught.exception), 'unresolved_import')
            write(tree, 'outside.ts', 'export const X = 1;\n')
            write(tree, 'supabase/functions/search-key/index.ts', "import { X } from '../../../outside.ts';\n")
            with self.assertRaises(deploy.DeployError) as caught:
                deploy.import_graph(tree / 'supabase/functions', 'search-key')
            self.assertEqual(str(caught.exception), 'import_outside_functions')

    def test_real_functions_resolve_and_exclude_tests(self):
        for slug in deploy.available_functions(ROOT):
            graph = deploy.import_graph(ROOT / 'supabase/functions', slug)
            self.assertIn(slug + '/index.ts', graph)
            self.assertFalse([path for path in graph if path.endswith('_test.ts')], slug)

    def test_plan_writes_slugs_and_graphs(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(base)
            output = Path(base) / 'out/plan.json'
            github_output = Path(base) / 'github_output'
            with mock.patch('sys.stdout', io.StringIO()):
                code = deploy.main(['plan', '--functions', 'all', '--root', str(tree),
                                    '--output', str(output), '--github-output', str(github_output)])
            self.assertEqual(code, 0)
            self.assertEqual(github_output.read_text(encoding='utf-8'), 'slugs=coach-chat,search-key\n')
            plan = json.loads(output.read_text(encoding='utf-8'))
            self.assertEqual(sorted(plan['graphs']), ['coach-chat', 'search-key'])


def git(repo, *args):
    """Runs git in a throwaway repository with a fixed identity."""
    import subprocess
    done = subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                           '-c', 'commit.gpgsign=false', *args], capture_output=True, text=True, check=True)
    return done.stdout.strip()


class RollbackGuardTest(unittest.TestCase):
    def test_every_function_has_a_full_floor_and_coach_chat_needs_preferences(self):
        self.assertEqual(sorted(deploy.ROLLBACK_FLOORS), sorted(deploy.PROBES))
        for slug, (sha, reason) in deploy.ROLLBACK_FLOORS.items():
            self.assertRegex(sha, r'^[0-9a-f]{40}$', slug)
            self.assertRegex(reason, r'^[a-z_]+$', slug)
        # Older coach-chat handlers reject the `preferences` field of #155 clients.
        self.assertEqual(deploy.ROLLBACK_FLOORS['coach-chat'][0], 'a3a7263bc9e915b99ac7984ff106d3d74dee8142')

    def test_a_target_below_a_floor_is_refused_unless_overridden(self):
        floors = {'coach-chat': (SHA_A, 'reason'), 'search-key': (SHA_B, 'reason')}
        contains = {(SHA_A, 'c' * 40): False, (SHA_B, 'c' * 40): True}
        with mock.patch.object(deploy, 'ROLLBACK_FLOORS', floors):
            refused = deploy.rollback_guard(['coach-chat', 'search-key'], 'c' * 40,
                                            lambda floor, target: contains[(floor, target)])
            self.assertEqual(refused['below_floor'], ['coach-chat'])
            self.assertFalse(refused['allowed'])
            self.assertFalse(refused['override'])
            allowed = deploy.rollback_guard(['coach-chat'], 'c' * 40,
                                            lambda floor, target: contains[(floor, target)], True)
            self.assertTrue(allowed['allowed'])
            self.assertTrue(allowed['override'])
            fine = deploy.rollback_guard(['search-key'], 'c' * 40,
                                         lambda floor, target: contains[(floor, target)], True)
            self.assertEqual((fine['below_floor'], fine['override'], fine['allowed']), ([], False, True))
            with self.assertRaises(deploy.DeployError) as caught:
                deploy.rollback_guard(['recipe-import'], 'c' * 40, lambda *args: True)
            self.assertEqual(str(caught.exception), 'no_rollback_floor_defined:recipe-import')

    def test_ancestry_comes_from_git_and_an_unknown_commit_is_an_error(self):
        with tempfile.TemporaryDirectory() as repo:
            git(repo, 'init', '-q')
            shas = []
            for name in ('old', 'floor', 'head'):
                write(repo, name + '.txt', name + '\n')
                git(repo, 'add', name + '.txt')
                git(repo, 'commit', '-q', '-m', name)
                shas.append(git(repo, 'rev-parse', 'HEAD'))
            old, floor, head = shas
            self.assertTrue(deploy.git_is_ancestor(repo, floor, head))
            self.assertTrue(deploy.git_is_ancestor(repo, floor, floor))
            self.assertFalse(deploy.git_is_ancestor(repo, floor, old))
            with self.assertRaises(deploy.DeployError) as caught:
                deploy.git_is_ancestor(repo, 'f' * 40, head)
            self.assertEqual(str(caught.exception), 'git_ancestry_unknown')
            with self.assertRaises(deploy.DeployError):
                deploy.git_is_ancestor(repo, 'HEAD~1', head)
            # The command refuses the rollback below the floor and records why.
            output = Path(repo) / 'out/guard.json'
            stderr = io.StringIO()
            with mock.patch.object(deploy, 'ROLLBACK_FLOORS', {'coach-chat': (floor, 'reason')}), \
                    mock.patch('sys.stderr', stderr), mock.patch('sys.stdout', io.StringIO()):
                code = deploy.main(['guard', '--slugs', 'coach-chat', '--target-sha', old,
                                    '--repo', repo, '--output', str(output)])
                self.assertEqual(code, 1)
                self.assertIn('::error::coach-chat', stderr.getvalue())
                self.assertEqual(json.loads(output.read_text(encoding='utf-8'))['below_floor'], ['coach-chat'])
                code = deploy.main(['guard', '--slugs', 'coach-chat', '--target-sha', old, '--repo', repo,
                                    '--output', str(output), '--allow-below-floor'])
                self.assertEqual(code, 0)
                self.assertTrue(json.loads(output.read_text(encoding='utf-8'))['override'])
                code = deploy.main(['guard', '--slugs', 'coach-chat', '--target-sha', head,
                                    '--repo', repo, '--output', str(output)])
                self.assertEqual(code, 0)


class MigrationGuardTest(unittest.TestCase):
    def tree(self, base, names):
        for name in names:
            write(base, 'supabase/migrations/' + name, 'select 1;\n')
        return Path(base)

    def api(self, handler):
        requests = []

        def open_url(request, timeout):
            requests.append(request)
            return handler(request)
        return deploy.Management(TOKEN, REF, open_url), requests

    def test_repository_versions_are_read_like_the_drift_job(self):
        with tempfile.TemporaryDirectory() as base:
            tree = self.tree(base, ['20260516150000_create_profiles.sql', '20261018100000_food.sql'])
            write(tree, 'supabase/migrations/README.md', 'notes\n')
            self.assertEqual(deploy.repo_migration_versions(tree), ['20260516150000', '20261018100000'])
            write(tree, 'supabase/migrations/draft_without_version.sql', 'select 1;\n')
            with self.assertRaises(deploy.DeployError):
                deploy.repo_migration_versions(tree)
        versions = deploy.repo_migration_versions(ROOT)
        self.assertEqual(len(versions), len(list((ROOT / 'supabase/migrations').glob('*.sql'))))

    def test_live_history_is_read_with_the_fixed_query_and_parsed_strictly(self):
        body = json.dumps([{'v': '20260516150000,20261018100000'}]).encode()
        api, requests = self.api(lambda request: FakeResponse(201, body))
        self.assertEqual(api.registered_migrations(), ['20260516150000', '20261018100000'])
        request = requests[0]
        self.assertEqual(request.full_url, 'https://api.supabase.com/v1/projects/' + REF + '/database/query')
        self.assertEqual(request.get_method(), 'POST')
        self.assertEqual(json.loads(request.data)['query'], deploy.MIGRATION_QUERY)
        self.assertIn('supabase_migrations.schema_migrations', deploy.MIGRATION_QUERY)
        self.assertTrue(request.get_header('User-agent').startswith('Mozilla/5.0'))
        for bad in (b'[]', b'[{"v": ""}]', b'[{"v": "2026,drop table"}]', b'{"v": "1"}', b'<html>'):
            api, _ = self.api(lambda request: FakeResponse(201, bad))
            with self.assertRaises(deploy.DeployError, msg=bad):
                api.registered_migrations()
        api, _ = self.api(lambda request: (_ for _ in ()).throw(http_error(request.full_url, 403, TOKEN.encode())))
        with self.assertRaises(deploy.DeployError) as caught:
            api.registered_migrations()
        self.assertEqual(str(caught.exception), 'management_http_403')

    def test_a_target_migration_missing_live_refuses_the_deploy(self):
        drift = deploy.migration_drift(['1', '2'], ['1', '2', '3'])
        self.assertEqual((drift['missing'], drift['registered']), (['3'], False))
        # A rollback target has fewer migrations than live: nothing is missing.
        self.assertTrue(deploy.migration_drift(['1', '2', '3'], ['1', '2'])['registered'])
        with tempfile.TemporaryDirectory() as base:
            tree = self.tree(base, ['1_a.sql', '2_b.sql', '3_c.sql'])
            output = Path(base) / 'out/migrations.json'
            body = json.dumps([{'v': '1,2'}]).encode()
            stderr = io.StringIO()
            with mock.patch.dict(os.environ, {'SUPABASE_ACCESS_TOKEN': TOKEN, 'SUPABASE_PROJECT_REF': REF}), \
                    mock.patch.object(deploy, 'opener', lambda: mock.Mock(open=lambda request, timeout: FakeResponse(201, body))), \
                    mock.patch('sys.stderr', stderr), mock.patch('sys.stdout', io.StringIO()):
                code = deploy.main(['migrations', '--root', str(tree), '--output', str(output)])
            self.assertEqual(code, 1)
            self.assertIn('not registered live: 3', stderr.getvalue())
            self.assertNotIn(TOKEN, stderr.getvalue())
            self.assertNotIn(REF, output.read_text(encoding='utf-8'))
            self.assertEqual(json.loads(output.read_text(encoding='utf-8'))['missing'], ['3'])


class CompareTest(unittest.TestCase):
    def live_copy(self, tree, live, slug, prefix='supabase/functions', newline='\n'):
        for relative in deploy.import_graph(tree / 'supabase/functions', slug):
            text = (tree / 'supabase/functions' / relative).read_text(encoding='utf-8')
            write(live, prefix + '/' + relative, text, newline)

    def test_identical_live_source_passes(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(Path(base) / 'checkout')
            live = Path(base) / 'live'
            self.live_copy(tree, live, 'coach-chat', prefix='tmp/runner/supabase/functions')
            result = deploy.compare('coach-chat', live, tree)
            self.assertTrue(result['identical'], result)
            self.assertEqual((result['graph_files'], result['live_files']), (4, 4))

    def test_crlf_upload_fails_strictly_and_passes_when_ignored(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(Path(base) / 'checkout')
            live = Path(base) / 'live'
            self.live_copy(tree, live, 'coach-chat', newline='\r\n')
            strict = deploy.compare('coach-chat', live, tree)
            self.assertFalse(strict['identical'])
            self.assertEqual(len(strict['different']), 4)
            self.assertTrue(deploy.compare('coach-chat', live, tree, ignore_crlf=True)['identical'])

    def test_missing_changed_and_foreign_files_fail(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(Path(base) / 'checkout')
            live = Path(base) / 'live'
            self.live_copy(tree, live, 'coach-chat')
            (live / 'supabase/functions/_shared/http.ts').unlink()
            write(live, 'supabase/functions/coach-chat/handler.ts', 'export const changed = true;\n')
            write(live, 'supabase/functions/coach-chat/injected.ts', 'export {};\n')
            write(live, 'supabase/functions/_shared/http_test.ts', "import { A } from './http.ts';\n")
            result = deploy.compare('coach-chat', live, tree)
            self.assertFalse(result['identical'])
            self.assertEqual(result['missing'], ['_shared/http.ts'])
            self.assertEqual(result['different'], ['coach-chat/handler.ts'])
            self.assertEqual(result['foreign'], ['coach-chat/injected.ts'])
            # An uploaded file outside the graph that equals the checkout is only noted.
            self.assertEqual(result['extra_identical'], ['_shared/http_test.ts'])

    def test_a_missing_type_only_module_is_noted_not_failed(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(Path(base) / 'checkout')
            live = Path(base) / 'live'
            self.live_copy(tree, live, 'coach-chat')
            (live / 'supabase/functions/_shared/types.ts').unlink()
            result = deploy.compare('coach-chat', live, tree)
            self.assertTrue(result['identical'], result)
            self.assertEqual(result['missing_type_only'], ['_shared/types.ts'])

    def test_unusable_download_layouts_are_errors(self):
        with tempfile.TemporaryDirectory() as base:
            tree = function_tree(Path(base) / 'checkout')
            live = Path(base) / 'live'
            live.mkdir()
            with self.assertRaises(deploy.DeployError) as caught:
                deploy.compare('coach-chat', live, tree)
            self.assertEqual(str(caught.exception), 'live_entrypoint_missing')
            self.live_copy(tree, live, 'coach-chat', prefix='one/functions')
            self.live_copy(tree, live, 'coach-chat', prefix='two/functions')
            with self.assertRaises(deploy.DeployError) as caught:
                deploy.compare('coach-chat', live, tree)
            self.assertEqual(str(caught.exception), 'live_layout_ambiguous')


class ManagementTest(unittest.TestCase):
    def api(self, handler):
        requests = []

        def open_url(request, timeout):
            requests.append(request)
            return handler(request)
        return deploy.Management(TOKEN, REF, open_url), requests

    def test_metadata_is_allowlisted_and_reads_the_fixed_host(self):
        body = json.dumps({'version': 57, 'status': 'ACTIVE', 'verify_jwt': True, 'updated_at': 1789510593799,
                           'slug': 'coach-chat', 'entrypoint_path': 'file:///private/path/index.ts',
                           'secret_hint': 'sensitive-field'}).encode()
        api, requests = self.api(lambda request: FakeResponse(200, body))
        self.assertEqual(api.function('coach-chat'),
                         {'version': 57, 'status': 'ACTIVE', 'verify_jwt': True, 'updated_at': 1789510593799})
        self.assertEqual(requests[0].full_url, 'https://api.supabase.com/v1/projects/' + REF + '/functions/coach-chat')
        self.assertEqual(requests[0].get_header('Authorization'), 'Bearer ' + TOKEN)

    def test_unknown_values_never_pass_as_healthy(self):
        body = json.dumps({'version': '57', 'status': 'ACTIVE; ok', 'verify_jwt': 'true'}).encode()
        api, _ = self.api(lambda request: FakeResponse(200, body))
        self.assertEqual(api.function('coach-chat'),
                         {'version': None, 'status': 'other', 'verify_jwt': False, 'updated_at': None})

    def test_missing_function_and_errors(self):
        api, _ = self.api(lambda request: (_ for _ in ()).throw(http_error(request.full_url, 404)))
        self.assertIsNone(api.function('coach-chat'))
        api, _ = self.api(lambda request: (_ for _ in ()).throw(http_error(request.full_url, 401, TOKEN.encode())))
        result = deploy.metadata(api, ['coach-chat'])
        self.assertEqual(result, {'coach-chat': {'exists': None, 'error': 'management_http_401'}})
        self.assertNotIn(TOKEN, json.dumps(result))
        api, _ = self.api(lambda request: FakeResponse(200, b'<html>'))
        self.assertEqual(deploy.metadata(api, ['search-key'])['search-key']['error'], 'management_invalid_json')

    def test_project_reference_and_slug_are_validated_before_any_request(self):
        with self.assertRaises(deploy.DeployError):
            deploy.Management(TOKEN, 'https://evil.invalid/')
        api, requests = self.api(lambda request: FakeResponse(200, b'{}'))
        with self.assertRaises(deploy.DeployError):
            api.function('../projects')
        self.assertEqual(requests, [])


class ProbeTest(unittest.TestCase):
    def fake(self, verify_jwt=True, booted=True):
        requests = []

        def open_url(request, timeout):
            requests.append(request)
            slug = request.full_url.rsplit('/', 1)[1]
            code = sorted(deploy.PROBES[slug][1])[0]
            if request.get_method() == 'OPTIONS':
                return FakeResponse(204, b'')
            authorized = request.get_header('Authorization') is not None
            if not authorized and verify_jwt:
                raise http_error(request.full_url, 401, b'{"code":401,"message":"Missing authorization header"}')
            if not booted:
                raise http_error(request.full_url, 503, b'{"code":"BOOT_ERROR","message":"Function failed to start"}')
            raise http_error(request.full_url, 401, json.dumps({'error': code}).encode())
        return open_url, requests

    def test_a_booted_function_behind_verify_jwt_passes(self):
        open_url, requests = self.fake()
        result = deploy.probe(['coach-chat', 'search-key'], REF, ANON, open_url)
        self.assertTrue(all(item['passed'] for item in result.values()), result)
        self.assertEqual(result['coach-chat']['statuses'], {'preflight': 204, 'no_token': 401, 'anon_key': 401})
        self.assertTrue(all(request.full_url.startswith('https://' + REF + '.supabase.co/functions/v1/')
                            for request in requests))
        self.assertEqual({request.get_method() for request in requests if request.full_url.endswith('search-key')},
                         {'OPTIONS', 'GET'})
        self.assertNotIn(ANON, json.dumps(result))

    def test_verify_jwt_off_or_a_boot_error_fails(self):
        open_url, _ = self.fake(verify_jwt=False)
        result = deploy.probe(['analyze-meal'], REF, ANON, open_url)['analyze-meal']
        self.assertFalse(result['passed'])
        self.assertFalse(result['checks']['gateway_401_without_token'])
        open_url, _ = self.fake(booted=False)
        result = deploy.probe(['recipe-import'], REF, ANON, open_url)['recipe-import']
        self.assertFalse(result['checks']['handler_answers_anon_key'])

    def test_transport_failure_is_a_failed_probe(self):
        def open_url(request, timeout):
            raise OSError('connection reset')
        self.assertFalse(deploy.probe(['coach-chat'], REF, ANON, open_url)['coach-chat']['passed'])


class RecordTest(unittest.TestCase):
    NOW = dt.datetime(2026, 10, 18, 12, 0, tzinfo=dt.timezone.utc)
    ENV = {'GITHUB_SERVER_URL': 'https://github.com', 'GITHUB_REPOSITORY': 'mxritzgit/Eatova',
           'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'SUPABASE_CLI_VERSION': '2.120.0',
           'SUPABASE_PROJECT_REF': REF, 'SUPABASE_ACCESS_TOKEN': TOKEN, 'SUPABASE_ANON_KEY': ANON}

    def directory(self, base, slugs=('coach-chat', 'search-key'), deployed=None, identical=True):
        directory = Path(base)
        directory.mkdir(parents=True, exist_ok=True)
        deploy.write_json(directory / 'plan.json', {'slugs': list(slugs), 'planned_at': '2026-10-18T11:58:00+00:00'})
        deploy.write_json(directory / 'before.json', {slug: {'exists': True, 'version': 10, 'status': 'ACTIVE',
                                                             'verify_jwt': True} for slug in slugs})
        deploy.write_json(directory / 'after.json', {slug: {'exists': True, 'version': 11, 'status': 'ACTIVE',
                                                            'verify_jwt': True} for slug in slugs})
        deploy.write_json(directory / 'probe.json', {slug: {'passed': True, 'checks': {}, 'statuses': {}} for slug in slugs})
        for slug in slugs:
            deploy.write_json(directory / ('after-' + slug + '.json'), {'identical': identical, 'graph_files': 3})
            if deployed is None or slug in deployed:
                (directory / ('deployed-' + slug)).touch()
        return directory

    def test_a_verified_deploy_is_a_success_without_secrets_or_project_ref(self):
        with tempfile.TemporaryDirectory() as base:
            record = deploy.build_record(self.directory(base), 'success', SHA_A, SHA_A, self.ENV, self.NOW)
            self.assertEqual(record['result'], 'success')
            self.assertFalse(record['rollback'])
            self.assertEqual([item['version_after'] for item in record['functions']], [11, 11])
            self.assertEqual(record['run_url'], 'https://github.com/mxritzgit/Eatova/actions/runs/123')
            text = json.dumps(record)
            for secret in (REF, TOKEN, ANON):
                self.assertNotIn(secret, text)
            self.assertIn('| `coach-chat` | 10 -> 11 |', deploy.markdown(record))

    def test_any_unproven_check_fails_the_record(self):
        cases = {
            'partial deploy': dict(deployed=('coach-chat',)),
            'source differs': dict(identical=False),
        }
        for name, options in cases.items():
            with tempfile.TemporaryDirectory() as base:
                record = deploy.build_record(self.directory(base, **options), 'failure', SHA_A, SHA_A,
                                             self.ENV, self.NOW)
                self.assertEqual(record['result'], 'failure', name)
        with tempfile.TemporaryDirectory() as base:
            directory = self.directory(base)
            deploy.write_json(directory / 'after.json', {'coach-chat': {'version': 11, 'status': 'ACTIVE',
                                                                        'verify_jwt': False}})
            (directory / 'probe.json').unlink()
            record = deploy.build_record(directory, 'success', SHA_A, SHA_A, self.ENV, self.NOW)
            checks = record['functions'][0]['checks']
            self.assertEqual(record['result'], 'failure')
            self.assertFalse(checks['verify_jwt'])
            self.assertFalse(checks['boot_probe'])
            self.assertFalse(record['functions'][1]['checks']['new_version'])

    def test_an_older_commit_is_recorded_as_rollback(self):
        with tempfile.TemporaryDirectory() as base:
            record = deploy.build_record(self.directory(base), 'success', SHA_B, SHA_A, self.ENV, self.NOW)
            self.assertTrue(record['rollback'])
            self.assertEqual((record['source_sha'], record['main_head_sha']), (SHA_B, SHA_A))
            self.assertEqual((record['below_rollback_floor'], record['rollback_floor_override'],
                              record['migrations_registered']), ([], False, None))

    def test_guard_results_and_an_override_are_recorded(self):
        with tempfile.TemporaryDirectory() as base:
            directory = self.directory(base)
            deploy.write_json(directory / 'guard.json', {'below_floor': ['coach-chat', '../x'], 'override': True})
            deploy.write_json(directory / 'migrations.json', {'registered': True, 'missing': []})
            record = deploy.build_record(directory, 'success', SHA_B, SHA_A, self.ENV, self.NOW)
            self.assertEqual(record['below_rollback_floor'], ['coach-chat'])
            self.assertTrue(record['rollback_floor_override'])
            self.assertTrue(record['migrations_registered'])
            self.assertIn('lowest safe rollback commit of: `coach-chat` (override)', deploy.markdown(record))

    def test_probe_summary_holds_statuses_only(self):
        results = {'coach-chat': {'passed': True, 'statuses': {'preflight': 204, 'no_token': 401, 'anon_key': 401}},
                   'search-key': {'passed': False, 'statuses': {'preflight': None, 'no_token': None, 'anon_key': None}}}
        text = deploy.probe_markdown(results)
        self.assertIn('Boot probe: FAILED', text)
        self.assertIn('| `coach-chat` | 204 | 401 | 401 | yes |', text)
        self.assertIn('| `search-key` | None | None | None | **no** |', text)
        self.assertIn('Boot probe: OK', deploy.probe_markdown({'coach-chat': results['coach-chat']}))

    def test_record_command_exit_code_and_summary(self):
        with tempfile.TemporaryDirectory() as base:
            directory = self.directory(Path(base) / 'deploy')
            summary = Path(base) / 'summary.md'
            with mock.patch.dict(os.environ, self.ENV), mock.patch('sys.stdout', io.StringIO()):
                code = deploy.main(['record', '--dir', str(directory), '--deploy-outcome', 'success',
                                    '--source-sha', SHA_A, '--main-sha', SHA_A,
                                    '--output', str(Path(base) / 'record/deploy-record.json'),
                                    '--summary', str(summary)])
            self.assertEqual(code, 0)
            self.assertIn('Edge Function deploy: SUCCESS', summary.read_text(encoding='utf-8'))

    def test_secret_errors_print_categories_only(self):
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {'SUPABASE_ACCESS_TOKEN': 'token with space ' + TOKEN,
                                          'SUPABASE_PROJECT_REF': REF}), mock.patch('sys.stderr', stderr):
            code = deploy.main(['metadata', '--slugs', 'coach-chat', '--output', os.devnull])
        self.assertEqual(code, 2)
        self.assertIn('missing_or_invalid_supabase_access_token', stderr.getvalue())
        self.assertNotIn(TOKEN, stderr.getvalue())


def run_blocks(text):
    """The script text of every `run:` step."""
    blocks, lines, index = [], text.splitlines(), 0
    while index < len(lines):
        match = re.match(r'^(\s*)(?:- )?run:\s*(.*)$', lines[index])
        if not match:
            index += 1
            continue
        indent, rest = len(match.group(1)), match.group(2)
        if rest not in ('|', '>'):
            blocks.append(rest)
            index += 1
            continue
        body, index = [], index + 1
        while index < len(lines) and (not lines[index].strip() or len(lines[index]) - len(lines[index].lstrip()) > indent):
            body.append(lines[index])
            index += 1
        blocks.append('\n'.join(body))
    return blocks


class WorkflowPolicyTest(unittest.TestCase):
    """The repository has no workflow linter job; these rules are enforced here."""

    def setUp(self):
        self.text = WORKFLOW.read_text(encoding='utf-8')
        # Without comment lines, which may name what the workflow never does.
        self.code = '\n'.join(line for line in self.text.splitlines() if not line.lstrip().startswith('#'))

    def test_every_action_in_every_workflow_is_pinned_to_a_commit(self):
        for workflow in sorted((ROOT / '.github/workflows').glob('*.yml')):
            for line in workflow.read_text(encoding='utf-8').splitlines():
                match = re.search(r'\buses:\s*(\S+)', line)
                if match:
                    self.assertRegex(match.group(1), r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$', f'{workflow.name}: {line}')
                    self.assertRegex(line, r'#\s*v\d', f'{workflow.name}: version comment missing: {line}')

    def test_untrusted_values_never_reach_a_shell_directly(self):
        for workflow in sorted((ROOT / '.github/workflows').glob('*.yml')):
            for block in run_blocks(workflow.read_text(encoding='utf-8')):
                self.assertNotRegex(block, r'\$\{\{\s*(inputs\.|github\.event\.|github\.head_ref|steps\.[^}]*outputs)',
                                    f'{workflow.name}: pass it through env instead')
        self.assertNotRegex('\n'.join(run_blocks(self.text)), r'\$\{\{', 'deploy workflow: no expressions in run')

    def test_manual_main_only_with_approval_and_least_privilege(self):
        trigger = re.search(r'(?ms)^on:\n(.*?)^\S', self.text).group(1)
        self.assertEqual(re.findall(r'(?m)^  (\w+):', trigger), ['workflow_dispatch'])
        self.assertRegex(self.text, r"(?m)^permissions:\n  contents: read\n\n")
        self.assertIsNone(re.search(r'(?m)^[ \t]+permissions:', self.text), 'no job-level permission changes')
        self.assertIsNone(re.search(r'\bwrite\b', self.code), 'no write permission')
        self.assertRegex(self.text, r"(?m)^    if: github\.repository == 'mxritzgit/Eatova' && github\.ref == 'refs/heads/main'$")
        self.assertRegex(self.text, r'(?m)^    environment: supabase-deploy$')
        self.assertRegex(self.text, r'(?m)^  cancel-in-progress: false$')
        self.assertIn('persist-credentials: false', self.text)

    def test_rollback_target_must_be_on_main_and_tooling_comes_from_main(self):
        self.assertIn('git merge-base --is-ancestor "$sha" "$MAIN_HEAD"', self.text)
        self.assertIn("grep -Eq '^[0-9a-f]{40}$'", self.text)
        self.assertIn('git worktree add --detach "$RUNNER_TEMP/target" "$sha"', self.text)
        self.assertIn('python3 scripts/operations/deploy_functions.py plan', self.text)

    def test_pinned_cli_deploys_through_the_api_and_keeps_verify_jwt(self):
        self.assertRegex(self.text, r'(?m)^  SUPABASE_CLI_VERSION: 2\.120\.0$')
        self.assertIn('sha256sum --check', self.text)
        self.assertIn("grep -Eq '^[0-9a-f]{64}$'", self.text, 'an unpinned checksum fails closed')
        self.assertRegex(self.text, r'functions deploy "\$slug" \\\n\s+--project-ref "\$SUPABASE_PROJECT_REF" --use-api')
        self.assertNotIn('--no-verify-jwt', self.code)
        self.assertNotIn('verify_jwt = false', self.code)
        for step in ('compare --slug', 'probe --slugs', 'record --dir', 'upload-artifact'):
            self.assertIn(step, self.text)

    def test_floor_and_migration_guards_run_before_the_first_deploy(self):
        deploy_step = self.text.index('      - name: Deploy\n')
        floor = self.text.index('deploy_functions.py guard --slugs "$SLUGS"')
        migrations = self.text.index('deploy_functions.py migrations --root "$RUNNER_TEMP/target"')
        self.assertLess(floor, deploy_step)
        self.assertLess(migrations, deploy_step)
        self.assertLess(self.text.index('python3 scripts/operations/deploy_functions.py plan'), floor)
        self.assertIn('--target-sha "$TARGET_SHA" --repo .', self.text)
        # The override is a typed input, reaches the shell only through env and
        # is off by default.
        self.assertRegex(self.text, r"(?ms)      allow_below_floor:\n.*?default: false\n        type: boolean")
        self.assertIn('ALLOW_BELOW_FLOOR: ${{ inputs.allow_below_floor }}', self.text)
        self.assertIn('if [ "$ALLOW_BELOW_FLOOR" = "true" ]; then', self.text)
        # Neither guard step tolerates its own failure.
        for name in ('Rollback floor', 'Target migrations registered live'):
            step = self.text[self.text.index('- name: ' + name):]
            step = step[:step.index('\n      - ')]
            self.assertNotIn('|| true', step, name)
            self.assertNotIn('continue-on-error', step, name)
            self.assertNotIn('if:', step, name)

    def test_secrets_come_from_the_environment_into_step_env_only(self):
        names = set(re.findall(r'\$\{\{\s*secrets\.(\w+)\s*\}\}', self.text))
        self.assertEqual(names, {'SUPABASE_ACCESS_TOKEN', 'SUPABASE_PROJECT_REF', 'SUPABASE_ANON_KEY'})
        for line in self.text.splitlines():
            if 'secrets.' in line:
                self.assertRegex(line, r'^\s+(SUPABASE_[A-Z_]+): \$\{\{ secrets\.\1 \}\}$', line)
        self.assertNotRegex(self.text, r'echo[^\n]*\$(SUPABASE_ACCESS_TOKEN|SUPABASE_ANON_KEY)', 'never echo a secret')


if __name__ == '__main__':
    unittest.main()
