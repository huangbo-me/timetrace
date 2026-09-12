"""仅在临时仓库测试发布控制，不调用 Apple 或 Xcode。"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_notes_include_dirty_inventory_and_preserve_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root).decode().strip()
            git('init', '-q')
            git('config', 'user.email', 'test@example.com')
            git('config', 'user.name', 'Test')
            (root / '.gitignore').write_text('build/\n')
            (root / 'app.swift').write_text('before')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (root / 'app.swift').write_text('after')
            git('commit', '-qam', 'fix: 修复记录显示')
            (root / 'new.swift').write_text('untracked')
            def resolve(lane, **env):
                self.assertEqual(lane, 'release_resolve')
                Path(env['RELEASE_VERSION_RESULT']).write_text(json.dumps({'version': '0.1.2'}))
            args = ['release.py', 'notes', '--version', '0.1.1', '--base', base]
            with patch.dict(os.environ, {'TIMETRACE_RELEASE_ROOT': str(root / 'build/releases')}), patch.object(release, 'ROOT', root), patch.object(release, 'call_fastlane', resolve), patch.object(sys, 'argv', args):
                release.main()
                directory = root / 'build/releases/0.1.2/attempt-1'
                self.assertIn('修复记录显示', (directory / 'release-notes.txt').read_text())
                self.assertIn('new.swift', (directory / 'changes.md').read_text())
                state = json.loads((directory / 'state.json').read_text())
                self.assertEqual(state['source'], release.snapshot())
                (root / 'new.swift').write_text('changed')
                self.assertNotEqual(state['source'], release.snapshot())
                with self.assertRaisesRegex(ValueError, '已有发布资料'):
                    release.main()
                with patch.object(sys, 'argv', ['release.py', 'submit', '--version', '0.1.2']):
                    with self.assertRaisesRegex(ValueError, '先运行 archive'):
                        release.main()


if __name__ == '__main__':
    unittest.main()
