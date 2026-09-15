"""Real loopback servers prove no redirect/proxy credential forwarding."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts' / 'security'))
from local_auth_transport import LocalAuthClient, direct_subprocess_environment


@contextlib.contextmanager
def server(*, redirect=None):
    seen = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.path)
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.send_response(302 if redirect else 200)
            if redirect:
                self.send_header('Location', redirect)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'ok': True}).encode())

        do_POST = do_GET

        def log_message(self, *_):
            pass

    instance = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{instance.server_port}', seen
    finally:
        instance.shutdown()
        thread.join(timeout=2)
        instance.server_close()


class LocalAuthTransportTests(unittest.TestCase):
    def deno_fetch(self, origin, environment):
        executable = shutil.which('deno')
        self.assertIsNotNone(executable, 'Deno 2 must be installed for the transport regression')
        source = (
            'const response = await fetch(' + json.dumps(origin + '/user') + ','
            '{headers:{Authorization:"Bearer synthetic-local-token"},redirect:"error"});'
            'console.log(JSON.stringify({status:response.status,'
            'environmentKept:Deno.env.get("AUTH_PROBE_SYNTHETIC_VALUE")==="fixture-kept"}));'
        )
        with tempfile.TemporaryDirectory(prefix='eatova-deno-transport-') as folder:
            script = Path(folder) / 'fetch.ts'
            script.write_text(source, encoding='utf-8')
            result = subprocess.run([
                executable, 'run', '--no-config', '--allow-env',
                '--allow-net=' + origin.removeprefix('http://'), str(script),
            ], env=direct_subprocess_environment(environment), capture_output=True,
                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, 'Deno must complete the direct local request')
        self.assertEqual(json.loads(result.stdout), {'status': 200, 'environmentKept': True})

    def test_deno_environment_proxy_cannot_receive_auth_requests(self):
        for key in ('HTTP_PROXY', 'http_proxy', 'ALL_PROXY'):
            with self.subTest(variable=key):
                with server() as (proxy, proxy_seen), server() as (origin, origin_seen):
                    # Remove the operator's routing first: every candidate proxy
                    # in this regression is another synthetic loopback server.
                    env = {name: value for name, value in os.environ.items()
                           if not name.lower().endswith('_proxy')}
                    env.update({key: proxy, 'NO_PROXY': '', 'no_proxy': '',
                                'AUTH_PROBE_SYNTHETIC_VALUE': 'fixture-kept'})
                    self.deno_fetch(origin, env)
                    self.assertEqual(proxy_seen, [], 'Deno must never forward auth to the proxy')
                    self.assertEqual(origin_seen, ['/user'])

    def test_deno_direct_origin_preserves_required_environment(self):
        with server() as (origin, seen):
            env = {name: value for name, value in os.environ.items()
                   if not name.lower().endswith('_proxy')}
            env['AUTH_PROBE_SYNTHETIC_VALUE'] = 'fixture-kept'
            self.deno_fetch(origin, env)
            self.assertEqual(seen, ['/user'])

    def test_subprocess_proxy_variables_are_removed_case_insensitively(self):
        env = {'PATH': 'synthetic-path', 'SUPABASE_URL': 'https://ci.invalid'}
        for key in ('HTTP_PROXY', 'https_proxy', 'All_Proxy', 'No_PrOxY'):
            env[key] = 'http://127.0.0.1:1'
        self.assertEqual(direct_subprocess_environment(env), {
            'PATH': 'synthetic-path', 'SUPABASE_URL': 'https://ci.invalid',
        })

    def test_proxy_environment_cannot_receive_auth_requests(self):
        with server() as (proxy, proxy_seen), server() as (origin, origin_seen):
            with patch.dict(os.environ, {
                'http_proxy': proxy, 'HTTP_PROXY': proxy,
                'no_proxy': '', 'NO_PROXY': '',
            }):
                client = LocalAuthClient(origin)
                status, body = client.request('/user', token='synthetic-local-token')
            self.assertEqual((status, body), (200, {'ok': True}))
            self.assertEqual(proxy_seen, [], 'No request may reach the proxy')
            self.assertEqual(origin_seen, ['/user'])

    def test_redirect_cannot_forward_auth_to_another_service(self):
        with server() as (target, target_seen):
            with server(redirect=target + '/capture') as (origin, origin_seen):
                status, _ = LocalAuthClient(origin).request(
                    '/user', token='synthetic-local-token',
                )
            self.assertEqual(status, 302, 'The redirect itself is returned')
            self.assertEqual(origin_seen, ['/user'])
            self.assertEqual(target_seen, [], 'Redirect target never receives credentials')

    def test_normal_local_post_and_synthetic_ip_header_are_supported(self):
        with server() as (origin, seen):
            status, body = LocalAuthClient(origin, client_ip='198.51.100.23').request(
                '/token?grant_type=password', {'password': 'synthetic-only'},
            )
            self.assertEqual((status, body), (200, {'ok': True}))
            self.assertEqual(seen, ['/token?grant_type=password'])

    def test_external_origins_and_path_authorities_fail_before_io(self):
        for origin in ('https://127.0.0.1:54992', 'http://localhost:54992',
                       'http://example.test:54992', 'http://user@127.0.0.1:54992',
                       'http://127.0.0.1:54992/path', 'http://127.0.0.1:54992?q=1'):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                LocalAuthClient(origin)
        client = LocalAuthClient('http://127.0.0.1:54992')
        for path in ('http://example.test/path', '//example.test/path', '/path#fragment'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                client.request(path)


if __name__ == '__main__':
    unittest.main()
