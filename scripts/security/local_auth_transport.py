"""Loopback-only transport for disposable Auth verification, without proxies."""
import json
import urllib.error
import urllib.parse
import urllib.request


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class LocalAuthClient:
    def __init__(self, base, *, client_ip=None):
        url = urllib.parse.urlsplit(base)
        if (url.scheme != 'http' or url.hostname != '127.0.0.1' or
                url.username is not None or url.password is not None or
                not url.port or url.path not in ('', '/') or url.query or
                url.fragment):
            raise ValueError('Only a literal loopback Auth origin is allowed')
        self.base = base.rstrip('/')
        self.client_ip = client_ip
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), _NoRedirect(),
        )

    def request(self, path, data=None, token=None, method=None):
        target = urllib.parse.urlsplit(path)
        if not path.startswith('/') or target.scheme or target.netloc or target.fragment:
            raise ValueError('Only local Auth request paths are allowed')
        headers = {'Content-Type': 'application/json'}
        if self.client_ip:
            headers['X-Forwarded-For'] = self.client_ip
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(
            self.base + path,
            data=None if data is None else json.dumps(data).encode(),
            headers=headers, method=method,
        )
        try:
            response = self.opener.open(req, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise ValueError('Local Auth response exceeds limit')
            return response.code, json.loads(raw or b'{}')
