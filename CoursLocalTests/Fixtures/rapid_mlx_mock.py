"""Disposable loopback fixture for exercising URLSession/ATS/redirects, never a real AI server.
Run: python3 CoursLocalTests/Fixtures/rapid_mlx_mock.py
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-CoursLocal-Test-Fixture', 'true')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/health':
            self.respond({'status': 'ok'})
        elif self.path == '/v1/models':
            self.respond({'data': [{'id': 'fixture-model', 'owned_by': 'rapid-mlx', 'modality': 'text'}]})
        else:
            self.respond({'error': {'message': 'unknown route'}}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        if body.get('model') == 'redirect-test':
            self.send_response(302)
            self.send_header('Location', 'https://example.com/should-never-be-contacted')
            self.end_headers()
            return
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': 'Transport local vérifié'}, 'finish_reason': 'stop'}]})


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 38991), Handler)
    print('CoursLocal fixture: http://127.0.0.1:38991/v1', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
