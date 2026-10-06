#!/usr/bin/env python3
"""Run against the ZetTypst monorepo without modifying its template."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

plugin = Path(__file__).resolve().parents[1]
repo = Path(os.environ.get('ZETTYPST_REPO', plugin.parent)).resolve()
subprocess.run([sys.executable, str(repo / 'scripts/install-local.py'), '--link'], check=True)
subprocess.run(['cargo', 'build', '--workspace', '--locked'], cwd=repo, check=True)
subprocess.run([sys.executable, str(plugin / 'scripts/package_capture.py'), '--package-path', str(repo / '.dev/packages')], check=True)
with tempfile.TemporaryDirectory(prefix='zettypst-integration-') as temp:
    root = Path(temp) / 'project'
    other_root = Path(temp) / 'other-project'
    shutil.copytree(repo / 'kickstart/template', root)
    shutil.copytree(repo / 'kickstart/template', other_root)
    env = dict(os.environ, ZETTYPST_TEST_ROOT=str(root.resolve()),
               ZETTYPST_TEST_OTHER_ROOT=str(other_root.resolve()),
               ZETTYPST_TEST_LSP=str(repo / 'target/debug/zettyp-lsp'),
               TYPST_PACKAGE_PATH=str(repo / '.dev/packages'))
    subprocess.run(['nvim', '--headless', '-u', 'NONE', '-l', 'tests/integration.lua'],
                   cwd=plugin, env=env, check=True, timeout=90)
    subprocess.run(['nvim', '--headless', '-u', 'NONE', '-l', 'tests/autostart.lua'],
                   cwd=plugin, env=env, check=True, timeout=90)
