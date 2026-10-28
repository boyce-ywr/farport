import json
from pathlib import Path
import socketserver
import sys
import time

root = Path(sys.argv[1])


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = self.rfile.readline().decode().split()
        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
            pass
        if len(request) != 3:
            return
        path = request[1]
        with (root / 'requests.log').open('a') as output:
            output.write(path + '\n')
        scenario = json.loads((root / 'scenario.json').read_text())
        response = scenario.get('version' if path == '/version' else 'info', {})
        time.sleep(response.get('delay', 0))
        default = {'ApiVersion': '1.53'} if path == '/version' else {'ID': 'fixture-daemon'}
        content = response.get('raw', json.dumps(response.get('body', default))).encode()
        status = response.get('status', 200)
        header = f'HTTP/1.1 {status} fixture\r\nContent-Length: {len(content)}\r\nConnection: close\r\nLocation: http://invalid.invalid/\r\n\r\n'
        try:
            self.wfile.write(header.encode() + content)
        except BrokenPipeError:
            pass


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


with Server(str(root / 'engine.sock'), Handler) as server:
    server.serve_forever()
