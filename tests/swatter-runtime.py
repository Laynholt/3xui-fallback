"""Linux/Docker qualification; all containers, threads and files are task-owned."""
import http.client
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]


class Runtime(unittest.TestCase):
    def setUp(self):
        cls = type(self)
        (ROOT / '.tmp').mkdir(exist_ok=True)
        cls.temp = Path(tempfile.mkdtemp(prefix='swatter-', dir=ROOT / '.tmp'))
        cls.logs = cls.temp / 'logs'
        cls.logs.mkdir()
        cls.container = 'fallback-swatter-' + uuid.uuid4().hex[:12]
        cls.ports = []
        for _ in range(2):
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                cls.ports.append(sock.getsockname()[1])

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(403 if self.path.endswith('/forbidden') else
                                   404 if self.path.endswith('/missing') else 200)
                self.end_headers()
                self.wfile.write(json.dumps(dict(self.headers)).encode())

            def log_message(self, *_):
                pass

        cls.upstream = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.thread.start()
        self.addCleanup(cls.cleanup)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=example.test', '-keyout', str(cls.temp / 'key'),
                        '-out', str(cls.temp / 'cert')], check=True, capture_output=True)

    @classmethod
    def docker(cls, *args):
        return subprocess.run(['docker', *args], check=True, capture_output=True, text=True).stdout.strip()

    @classmethod
    def cleanup(cls):
        subprocess.run(['docker', 'rm', '-f', cls.container], capture_output=True)
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.thread.join()
        shutil.rmtree(cls.temp)

    @classmethod
    def start(cls, cidr, trailing=False):
        values = dict(SITE_DOMAIN='example.test', MOSQUITO_SWATTER_EVENTS='1',
                      PANEL_HTTPS_PORT=str(cls.ports[0]), SUBS_HTTPS_PORT=str(cls.ports[1]),
                      PANEL_ALLOWED_CIDR=cidr, PANEL_PATH_PREFIX='/hidden-panel',
                      SUBS_PATH_PREFIX='/private-subs')
        if trailing:
            values['PANEL_PATH_PREFIX'] += '/'
            values['SUBS_PATH_PREFIX'] += '/'
        for prefix in ('PANEL', 'SUBS'):
            values.update({prefix + '_BACKEND_' + k: v for k, v in dict(
                SCHEME='http', HOST='127.0.0.1', PORT=str(cls.upstream.server_port),
                TLS_NAME='127.0.0.1', SSL_VERIFY='off').items()})
        args = ['run', '-d', '--name', cls.container, '--network', 'host']
        for key, value in values.items():
            args += ['-e', key + '=' + value]
        for source, dest in [(ROOT / 'render.sh', '/etc/nginx/render.sh'),
                             (ROOT / 'nginx.conf', '/etc/nginx/templates/nginx.conf.template'),
                             (ROOT / 'subs-proxy.conf', '/etc/nginx/templates/subs-proxy.conf.template'),
                             (ROOT / 'swatter.js', '/etc/nginx/swatter.js'),
                             (ROOT / 'html', '/usr/share/nginx/html'),
                             (cls.temp / 'cert', '/etc/nginx/certs/fullchain.pem'),
                             (cls.temp / 'key', '/etc/nginx/certs/privkey.pem')]:
            args += ['-v', str(source) + ':' + dest + ':ro']
        compose = json.loads(cls.docker('compose', '--env-file', str(ROOT / '.env.example'),
            '-f', str(ROOT / 'docker-compose.yml'), '-f', str(ROOT / 'compose.swatter.yml'),
            'config', '--format', 'json'))['services']['nginx']
        # Compose config retains escaped dollars; up unescapes them at container creation.
        command = [arg.replace('$$', '$') for arg in compose['command']]
        args += ['-v', str(cls.logs) + ':/var/log/swatter',
                 os.environ.get('NGINX_IMAGE') or compose['image'], *command]
        cls.container_id = cls.docker(*args)
        print('Owned container:', cls.container_id, flush=True)
        for _ in range(100):
            try:
                cls.request('/ready')
                cls.docker('exec', cls.container, 'nginx', '-t')
                return
            except (OSError, subprocess.CalledProcessError):
                time.sleep(.05)
        raise AssertionError('nginx not ready: ' + cls.docker('logs', cls.container))

    @classmethod
    def request(cls, path, listener=0, ipv6=False, host='example.test'):
        conn = http.client.HTTPSConnection('::1' if ipv6 else '127.0.0.1', cls.ports[listener],
                                          context=ssl._create_unverified_context(), timeout=3)
        try:
            conn.request('GET', path, headers={'Host': host,
                'X-Real-IP': '8.8.8.8', 'X-Forwarded-For': '8.8.8.8', 'Authorization': 'SECRET_HEADER'})
            response = conn.getresponse()
            return response.status, response.read()
        finally:
            conn.close()

    @classmethod
    def events(cls):
        return [json.loads(line) for line in (cls.logs / 'http.jsonl').read_text().splitlines()]

    def test_normalized_raw_paths(self):
        self.start('::1/128')
        digest = lambda path: hashlib.sha256(path.encode()).hexdigest()
        for listener in (0, 1):
            for path in ['/./private-subs/SECRET', '/a/../private-subs/SECRET',
                         '//private-subs/SECRET', '/a/%2e%2e/private-subs/SECRET',
                         '/%2fprivate-subs/SECRET']:
                self.request(path, listener)
                record = self.events()[-1]
                self.assertEqual(record['path_hash'], digest('/_other'), path)
                self.assertEqual(record['route_class'], 'other')
                self.assertEqual(record['host'], 'example.test')
        for path in ['/./hidden-panel/login', '/a/../hidden-panel/login',
                     '//hidden-panel/login', '/a/%2e%2e/hidden-panel/login']:
            self.assertEqual(self.request(path)[0], 404)
            record = self.events()[-1]
            self.assertTrue(record['gate_denied'], path)
            self.assertEqual(record['path_hash'], digest('/_panel'))
        self.request('/_swatter_panel_denied.html')
        self.assertFalse(self.events()[-1]['gate_denied'])
        with self.assertRaises(http.client.RemoteDisconnected):
            self.request('/unknown', host='attacker.test')
        self.assertEqual(self.events()[-1]['host'], 'example.test')
        self.docker('rm', '-f', self.container)
        self.start('127.0.0.1/32', trailing=True)
        for listener, path, alias in [(0, '/hidden-panel/SECRET', '/_panel'),
                                      (1, '/private-subs/SECRET', '/_subscription')]:
            self.request(path, listener)
            self.assertEqual(self.events()[-1]['path_hash'], digest(alias))

    def test_end_to_end(self):
        self.start('127.0.0.1/32')
        for listener in (0, 1):
            for path in ('/probe-a?SECRET_QUERY', '/probe-b', '/probe-a?different',
                         '/private-subs/SECRET_TOKEN', '/hidden-panel/SECRET_PANEL', '/.env'):
                self.request(path, listener)
        self.assertEqual(self.request('/hidden-panel/forbidden')[0], 404)
        status, body = self.request('/hidden-panel/missing')
        self.assertEqual(status, 404)
        self.assertIn(b'404', body)
        self.assertNotIn(b'SECRET_HEADER', body)
        status, body = self.request('/hidden-panel/health')
        self.assertEqual(status, 200)
        headers = json.loads(body)
        self.assertEqual(headers['X-Real-IP'], '127.0.0.1')
        self.assertEqual(headers['X-Forwarded-For'], '127.0.0.1')
        with self.assertRaises(http.client.RemoteDisconnected):
            self.request('/hidden-panel/health', host='forged.test')
        self.assertEqual(self.request('/hidden-panel/health', ipv6=True)[0], 404)
        records = self.events()
        self.assertEqual(len(records), 18)  # Exactly one record for each completed request.
        self.assertEqual((self.logs / 'http.jsonl').stat().st_mode & 0o7, 0)
        self.assertEqual(sum(record['gate_denied'] for record in records), 1)
        self.assertEqual(records[-1]['peer_ip'], '::1')
        for offset in (1, 7):
            self.assertEqual(records[offset]['path_hash'], records[offset + 2]['path_hash'])
            self.assertNotEqual(records[offset]['path_hash'], records[offset + 1]['path_hash'])
        self.assertNotIn('SECRET', json.dumps(records))
        self.assertNotIn('hidden-panel', json.dumps(records))
        self.assertNotIn('private-subs', json.dumps(records))
        (ROOT / '.tmp' / 'swatter-runtime-fixture.jsonl').write_text(
            ''.join(json.dumps(record, separators=(',', ':')) + '\n' for record in records))
        legacy = self.docker('exec', self.container, 'sh', '-c',
            'cat /var/log/nginx/panel_access.log /var/log/nginx/subs_access.log '
            '/var/log/nginx/panel_error.log /var/log/nginx/subs_error.log')
        self.assertEqual(legacy, '')
        # Persistent file survives recreation; no bridge tail window.
        self.docker('rm', '-f', self.container)
        self.start('::1/128')
        self.assertGreater(len(self.events()), len(records))
        self.assertEqual(self.request('/hidden-panel/health')[0], 404)
        status, body = self.request('/hidden-panel/health', ipv6=True)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['X-Forwarded-For'], '::1')
        self.assertEqual(self.request('/private-subs/health', 1, ipv6=True)[0], 200)
        # Rename/create/USR1, rather than destructive copytruncate.
        old = self.logs / 'http.jsonl.1'
        (self.logs / 'http.jsonl').rename(old)
        (self.logs / 'http.jsonl').touch(mode=0o640)
        self.docker('kill', '--signal=USR1', self.container)
        for _ in range(50):
            self.request('/after-rotate')
            if (self.logs / 'http.jsonl').stat().st_size:
                break
            time.sleep(.05)
        self.assertTrue(self.events())
        self.assertTrue(old.stat().st_size)
        if os.environ.get('SWATTER_SOURCE'):
            sys.path.insert(0, os.environ['SWATTER_SOURCE'])
            from moskit_guard.readers import FileReader
            reader = FileReader({'path': str(self.logs / 'http.jsonl'), 'start_at_end': False})
            first = reader.poll()
            self.assertTrue(first)
            cursor = dict(reader.cursor)
            reader.close()
            reopened = FileReader({'path': str(self.logs / 'http.jsonl')}, cursor)
            self.assertEqual(reopened.poll(), [])
            self.request('/after-cursor-restart')
            self.assertEqual(len(reopened.poll()), 1)
            (self.logs / 'http.jsonl').rename(self.logs / 'http.jsonl.2')
            (self.logs / 'http.jsonl').touch(mode=0o640)
            self.docker('kill', '--signal=USR1', self.container)
            reopened.poll()  # Drain old inode before switching to the new file.
            time.sleep(.1)
            self.request('/after-reader-rotate')
            batch = reopened.poll()
            if not batch:
                batch = reopened.poll()
            self.assertEqual(len(batch), 1)
            reopened.close()
        else:
            print('NOT_RUN: collector cursor qualification requires SWATTER_SOURCE')


if __name__ == '__main__':
    unittest.main()
