#!/usr/bin/env python3
"""Legacy harness for the pre-optimization Python port on the VM host.

The optimized port has a different query set; use compare_vm_stored.py instead.

Creates only temporary script/config copies and local comparison artifacts.
The proxy freezes each unique response per day and refuses mutation endpoints.
"""
import argparse
import datetime as dt
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import http.client
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qsl, urlencode, urlsplit


def load(path):
    spec = importlib.util.spec_from_file_location('vm_port', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def samples(text):
    result = {}
    for line in text.splitlines():
        key, value, timestamp = line.rsplit(' ', 2)
        key = (key, int(timestamp))
        if key in result:
            raise ValueError('Duplicate sample')
        result[key] = float(value)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python-script', type=Path, required=True)
    parser.add_argument('--bash-script', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('days', nargs='+')
    args = parser.parse_args()
    port = load(args.python_script)
    cfg = port.read_config(args.config)
    args.output.mkdir(parents=True, exist_ok=True)
    transport = port.Client(cfg)
    responses = {}
    replay_only = False
    requests = {'bash': 0, 'python': 0, 'upstream': 0}
    errors = []
    phase = 'bash'

    class Proxy(BaseHTTPRequestHandler):
        def do_GET(self):
            url = urlsplit(self.path)
            if url.path not in ('/api/v1/query', '/api/v1/query_range', '/api/v1/export'):
                self.send_error(403)
                return
            key = url.path + '?' + urlencode(sorted(parse_qsl(url.query)))
            requests[phase] += 1
            try:
                if key not in responses:
                    if replay_only:
                        raise ValueError('Python query absent from Bash recording: ' + key)
                    connection = transport.connection
                    connection.request('GET', key, headers=transport.headers)
                    response = connection.getresponse()
                    body = response.read()
                    if response.status != 200:
                        raise ValueError('Upstream HTTP ' + str(response.status))
                    responses[key] = body
                    requests['upstream'] += 1
                body = responses[key]
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception as exc:
                errors.append(str(exc))
                self.send_error(502)

        def log_message(self, *args):
            pass

    server = HTTPServer(('127.0.0.1', 0), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    proxy_cfg = dict(cfg, VM_HOST='127.0.0.1', VM_PORT=str(server.server_port), VM_USER='', VM_PASSWORD='')
    report = {'reference_sha256': hashlib.sha256(args.bash_script.read_bytes()).hexdigest(),
              'python_sha256': hashlib.sha256(args.python_script.read_bytes()).hexdigest(), 'days': []}
    try:
        with tempfile.TemporaryDirectory(prefix='vm-python-compare-') as temporary:
            temporary = Path(temporary)
            bash = temporary / 'evcc-vm-aggregate.sh'
            bash.write_bytes(args.bash_script.read_bytes())
            conf = temporary / 'evcc-vm-aggregate.conf'
            conf.write_text('\n'.join(k + '=' + shlex.quote(v) for k, v in proxy_cfg.items()))
            conf.chmod(0o600)
            for day in args.days:
                responses.clear()
                requests = {'bash': 0, 'python': 0, 'upstream': 0}
                replay_only, phase = False, 'bash'
                parts = day.split('-')
                began = time.perf_counter()
                reference = subprocess.run(['bash', str(bash), '--dry-run', '--day', *parts], capture_output=True, text=True)
                bash_seconds = time.perf_counter() - began
                (args.output / (day + '.bash.prom')).write_text(reference.stdout)
                (args.output / (day + '.bash.log')).write_text(reference.stderr)
                if reference.returncode:
                    raise RuntimeError('Bash failed for ' + day)
                replay_only = True
                began = time.perf_counter()
                replay = subprocess.run(['bash', str(bash), '--dry-run', '--day', *parts], capture_output=True, text=True)
                bash_replay_seconds = time.perf_counter() - began
                if replay.returncode or samples(replay.stdout) != samples(reference.stdout):
                    raise RuntimeError('Bash replay differs')
                requests['bash'] = requests['bash'] // 2
                phase = 'python'
                began = time.perf_counter()
                candidate = subprocess.run([sys.executable, str(args.python_script), '--config', str(conf), '--dry-run', '--day', *parts], capture_output=True, text=True)
                python_seconds = time.perf_counter() - began
                (args.output / (day + '.python.prom')).write_text(candidate.stdout)
                (args.output / (day + '.python.log')).write_text(candidate.stderr)
                if candidate.returncode:
                    raise RuntimeError('Python failed for ' + day + ': ' + candidate.stderr + str(errors))
                expected, actual = samples(reference.stdout), samples(candidate.stdout)
                absent = sorted(str(k) for k in expected.keys() - actual.keys())
                extra = sorted(str(k) for k in actual.keys() - expected.keys())
                differences = []
                maximum = 0
                exact = 0
                for key in expected.keys() & actual.keys():
                    a, b = expected[key], actual[key]
                    relative = abs(b - a) / abs(a) if a else (0 if b == 0 else float('inf'))
                    maximum = max(maximum, relative)
                    exact += a == b
                    if relative > 0.01:
                        differences.append({'sample': str(key), 'bash': a, 'python': b, 'relative': relative})
                entry = {'day': day, 'samples': len(expected), 'exact': exact, 'maximum_relative_error': maximum,
                         'missing': absent, 'extra': extra, 'failures': differences,
                         'bash_seconds': bash_seconds, 'bash_replay_seconds': bash_replay_seconds, 'python_seconds': python_seconds, 'requests': dict(requests)}
                report['days'].append(entry)
                print(json.dumps(entry), flush=True)
                (args.output / 'summary.json').write_text(json.dumps(report, indent=2))
                if absent or extra or differences:
                    raise RuntimeError('Comparison failed')
    finally:
        server.shutdown()
        transport.connection.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
