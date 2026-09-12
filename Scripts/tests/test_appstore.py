import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('appstore', Path(__file__).parents[1] / 'appstore.py')
appstore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appstore)


class AppstoreTests(unittest.TestCase):
    def test_same_commit_prefers_completed_upload_over_failed_attempt(self):
        with tempfile.TemporaryDirectory() as temp:
            file = Path(temp) / 'state.json'
            file.write_text('{}')
            done = {'head': 'a', 'uploaded': True, 'ipa': 'app.ipa', '_path': file}
            failed = {'head': 'a', '_path': file}
            unrelated = {'head': 'b', 'submitted': True, '_path': file}
            self.assertIs(appstore.commit_state([done, failed, unrelated], 'a'), done)
            self.assertIsNone(appstore.commit_state([done], 'b'))

    def test_completed_upload_and_submission_make_no_external_calls(self):
        state = {'uploaded': True, 'submitted': True}
        with patch.object(appstore, 'run') as run:
            appstore.upload(state, {})
            appstore.review(state, {})
            run.assert_not_called()

    def test_bundle_isolation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for bundle in ['com.example.first', 'com.example.second']:
                file = root / bundle / '1.0/attempt-1/state.json'
                file.parent.mkdir(parents=True)
                file.write_text(json.dumps({'bundle_id': bundle, 'head': 'same'}))
            states = appstore.release_states(root, 'com.example.first')
            self.assertEqual(len(states), 1)
            self.assertEqual(states[0]['bundle_id'], 'com.example.first')

    def test_config_bundle_mismatch_stops_and_auto_uses_current_project(self):
        config = {'project': 'App.xcodeproj', 'scheme': 'App', 'bundle_id': 'com.wrong', 'release_root': '/tmp/out'}
        settings = json.dumps([{'buildSettings': {'FULL_PRODUCT_NAME': 'App.app',
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.actual', 'MARKETING_VERSION': '1.2'}}])
        with patch.object(appstore, 'run', return_value=settings):
            with self.assertRaisesRegex(ValueError, 'Bundle ID'):
                appstore.inspect_project(config, {})
            config['bundle_id'] = 'auto'
            env = {}
            self.assertEqual(appstore.inspect_project(config, env), '1.2')
            self.assertEqual(env['RELEASE_BUNDLE_ID'], 'com.actual')
            self.assertEqual(env['TIMETRACE_RELEASE_ROOT'], '/tmp/out/com.actual')

    def test_existing_ipa_does_not_archive_again(self):
        with tempfile.TemporaryDirectory() as temp:
            file = Path(temp) / 'state.json'
            state = {'ipa': 'existing.ipa', '_path': file, 'version': '1.0', 'build': '2'}
            with patch.object(appstore, 'confirm_notes'), patch.object(appstore, 'step') as step:
                appstore.upload(state, {})
                self.assertEqual(step.call_count, 1)
                self.assertEqual(step.call_args.args[0], 'upload')


if __name__ == '__main__':
    unittest.main()
