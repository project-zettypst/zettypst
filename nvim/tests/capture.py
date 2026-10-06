#!/usr/bin/env python3
"""Exercise capture through real LSP and framed native messaging; no public writes."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import subprocess
import tempfile
import threading

plugin = Path(__file__).resolve().parents[1]
repo = Path(os.environ.get('ZETTYPST_REPO', plugin.parent))
binary = Path(os.environ.get('ZETTYPST_TEST_LSP', repo / 'target/debug/zettyp-lsp'))
subprocess.run([sys.executable, str(plugin / 'scripts/package_capture.py'), '--package-path', str(repo / '.dev/packages')], check=True)
with tempfile.TemporaryDirectory(prefix='zettypst-capture-') as temp:
    tmp = Path(temp)
    root = tmp / 'project'
    shutil.copytree(repo / 'kickstart/template', root)
    (root / '.zettypst/captures.json').write_text('{}\n')
    pdf = tmp / 'paper.pdf'
    subprocess.run(['typst', 'compile', '-', str(pdf)], input=b'DOI: 10.1234/pdftext\n', check=True, capture_output=True)
    pdf_data = pdf.read_bytes()
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith('/crossref/'):
                data = json.dumps({'message': {'title': ['PDF text paper'], 'DOI': '10.1234/pdftext', 'type': 'journal-article', 'author': [{'given': 'Fixture', 'family': 'Author'}], 'issued': {'date-parts': [[2026]]}}}).encode()
                mime = 'application/json'
            elif self.path.startswith('/arxiv'):
                data = b'<feed><entry><title>arXiv fixture</title><published>2026-01-01</published><author><name>Fixture Author</name></author><summary>Fixture abstract</summary></entry></feed>'
                mime = 'application/atom+xml'
            elif self.path == '/paper.pdf':
                data, mime = pdf_data, 'application/pdf'
            else:
                data, mime = b'<html><head><title>Fixture Web Page</title><meta name="description" content="Fixture abstract"></head><body>Captured text</body></html>', 'text/html'
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f'http://127.0.0.1:{server.server_port}'
    env = dict(os.environ, ZETTYPST_TEST_ROOT=str(root), ZETTYPST_TEST_LSP=str(binary),
               CAPTURE_TEST_URL=endpoint, CAPTURE_TEST_PDF=str(pdf), TYPST_PACKAGE_PATH=str(repo / '.dev/packages'))
    try:
        subprocess.run(['typst', 'compile', '--root', str(plugin), 'tests/capture_merge.typ', str(tmp / 'merge.pdf')],
                       cwd=plugin, env=env, check=True, timeout=60)
        subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-l', 'tests/capture.lua'], cwd=plugin, env=env, check=True, timeout=120)
        cfg = tmp / 'native.json'
        cfg.write_text(json.dumps({'root': str(root), 'plugin_root': str(plugin), 'lsp': {
            'cmd': [str(binary), '--ignore-system-fonts'], 'init_options': {'entry': 'lsp.typ'},
            'cmd_env': {'TYPST_PACKAGE_PATH': str(repo / '.dev/packages')},
        }, 'options': {'entries': {'nodes': '.zettypst/host/nodes.typ', 'capture': '.zettypst/host/capture.typ'},
                       'capture': {'bibliography': {'path': 'ref.bib', 'translators': {'arxiv': False, 'crossref': False}}}}}))
        def native(payload):
            data = json.dumps(payload).encode()
            result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-l', str(plugin / 'lua/zettypst/capture/native_host.lua'), str(cfg)],
                                    input=struct.pack('<I', len(data)) + data, capture_output=True, env=env, check=True, timeout=60)
            assert len(result.stdout) >= 4, result.stderr.decode(errors='replace')
            length, = struct.unpack('<I', result.stdout[:4])
            assert len(result.stdout) == length + 4, result.stdout[:500]
            return json.loads(result.stdout[4:])
        assert native({'action': 'ping'})['status'] == 'pong'
        page = native({'action': 'capturePage', 'url': 'https://native-fixture.invalid/page', 'title': 'Native page', 'selection': 'Native selection'})
        assert page['ok'], page
        assert native({'action': 'capturePage', 'url': 'https://native-fixture.invalid/page', 'title': 'Native page'})['note_id'] == page['note_id']
        paper = native({'action': 'capturePdfFile', 'path': str(pdf), 'sourceUrl': 'https://native-fixture.invalid/paper.pdf', 'metadata': {'citation_title': 'Native PDF'}})
        assert paper['ok'], paper
        assert Path(paper['asset_path']).read_bytes() == pdf_data
        assert Path(paper['asset_path']).stem == hashlib.sha256(pdf_data).hexdigest()
        invalid = native({'action': 'capturePdfFile', 'path': str(root / 'invalid.pdf')})
        assert not invalid['ok']
        assert not native({'action': 'capturePdfUrl', 'url': endpoint + '/paper.pdf'})['ok']
        # Captured citations and note bodies must render, not merely evaluate.
        subprocess.run(['typst', 'compile', '--root', str(root), str(root / 'index.typ'), str(tmp / 'captured.pdf')], env=env, check=True, timeout=60)
        print('PASS native messaging: ping, browser page/PDF, repeat capture, non-PDF rejection, framing and final document compilation')
    finally:
        server.shutdown()
