"""Disposable, memory-only SMTP sink and template server for local GoTrue tests.

Run only inside the isolated Docker network created by local_email_template_probe.
No relay, filesystem mailbox, or external mail delivery is implemented.
"""
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socketserver
import threading

MESSAGES = []
LOCK = threading.Lock()
TEMPLATES = Path('/templates')


class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(15)
        self.wfile.write(b'220 eatova-local-test ESMTP\r\n')
        while line := self.rfile.readline(65536):
            command = line.split(b' ', 1)[0].strip().upper()
            if command in (b'EHLO', b'HELO'):
                self.wfile.write(b'250-eatova-local-test\r\n250 8BITMIME\r\n')
            elif command in (b'MAIL', b'RCPT', b'RSET', b'NOOP'):
                self.wfile.write(b'250 OK\r\n')
            elif command == b'DATA':
                self.wfile.write(b'354 End with dot\r\n')
                raw = bytearray()
                while part := self.rfile.readline(65536):
                    if part in (b'.\r\n', b'.\n'):
                        break
                    raw.extend(part[1:] if part.startswith(b'..') else part)
                    if len(raw) > 1024 * 1024:
                        return
                message = BytesParser(policy=policy.default).parsebytes(raw)
                html = message.get_body(preferencelist=('html',))
                with LOCK:
                    MESSAGES.append({'to': str(message['To']),
                                     'subject': str(message['Subject']),
                                     'html': html.get_content() if html else ''})
                self.wfile.write(b'250 Captured locally\r\n')
            elif command == b'QUIT':
                self.wfile.write(b'221 Bye\r\n')
                return
            else:
                self.wfile.write(b'502 Unsupported\r\n')


class API(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            body, kind = b'{}', 'application/json'
        elif self.path == '/messages':
            with LOCK:
                body = json.dumps(MESSAGES).encode()
            kind = 'application/json'
        elif self.path in ('/recovery.html', '/reauthentication.html'):
            body = (TEMPLATES / self.path[1:]).read_bytes()
            kind = 'text/html; charset=utf-8'
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if __name__ == '__main__':
    smtp = socketserver.ThreadingTCPServer(('0.0.0.0', 1025), SMTP)
    smtp.daemon_threads = True
    threading.Thread(target=smtp.serve_forever, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', 8025), API).serve_forever()
