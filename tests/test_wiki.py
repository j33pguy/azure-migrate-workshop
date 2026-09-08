"""Local publication/link protection tests; no GitHub or Azure calls."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('sync_wiki', Path(__file__).resolve().parents[1] / 'tools/sync_wiki.py')
wiki = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wiki)
REPO = 'j33pguy/azure-migrate-workshop'
REVISION = 'a' * 40


class WikiTests(unittest.TestCase):
    def test_links_are_rewritten_without_touching_code_or_external_urls(self):
        text = ('[guide](Module-1.md#heading) [helper](../scripts/tool.ps1) '
                '[external](https://learn.microsoft.com/example)\n'
                '```powershell\n[leave](Module-1.md)\n```\n')
        result = wiki.rewrite_links(text, 'docs/Module-0.md', {'docs/Module-1.md': 'Discovery'}, REPO, REVISION)
        self.assertIn('/wiki/Discovery#heading', result)
        self.assertIn(f'/blob/{REVISION}/scripts/tool.ps1', result)
        self.assertIn('https://learn.microsoft.com/example', result)
        self.assertIn('[leave](Module-1.md)', result)

    def test_render_extracts_architecture_and_resolves_home_environment_links(self):
        sources = {'wiki/Home.md': '[environment](../README.md#environment)',
                   'README.md': '# Workshop\n\n## Environment\nDiagram\n\n## Start here\nOther content\n'}
        spec = [{'page': 'Home', 'source': 'wiki/Home.md'}, {'page': 'Architecture', 'source': 'README.md', 'section': 'Environment'}]
        pages = wiki.render_pages(spec, sources.__getitem__, REPO, REVISION)
        self.assertIn('/wiki/Architecture)', pages['Home.md'])
        self.assertIn('Diagram', pages['Architecture.md'])
        self.assertNotIn('Other content', pages['Architecture.md'])
        self.assertIn(f'/blob/{REVISION}/README.md', pages['Architecture.md'])

    def test_case_collisions_and_escaping_paths_are_rejected(self):
        with self.assertRaises(ValueError):
            wiki.render_pages([{'page': 'Home', 'source': 'a.md'}, {'page': 'home', 'source': 'b.md'}], lambda _: '', REPO, REVISION)
        with self.assertRaises(ValueError):
            wiki.render_pages([{'page': 'Home', 'source': '../secret.md'}], lambda _: '', REPO, REVISION)
        with self.assertRaises(ValueError):
            wiki.rewrite_links('[bad](../../secret)', 'docs/test.md', {}, REPO, REVISION)

    def test_unknown_wiki_destination_is_rejected(self):
        with self.assertRaises(ValueError):
            wiki.render_pages([{'page': 'Home', 'source': 'wiki/Home.md'}], lambda _: f'[bad](https://github.com/{REPO}/wiki/Missing)', REPO, REVISION)

    def test_initial_home_adoption_and_custom_page_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'Home.md').write_text('Welcome')
            (path / 'Custom.md').write_text('User content')
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Workshop'}, REPO, REVISION)
            wiki.publish_local(path, {'Home.md': 'Workshop'}, REPO, REVISION, adopt_home=True)
            self.assertEqual((path / 'Custom.md').read_text(), 'User content')
            self.assertEqual((path / 'Home.md').read_text(), 'Workshop')
            wiki.publish_local(path, {'Home.md': 'Workshop'}, REPO, REVISION, check=True)

    def test_manual_edits_stop_all_writes_even_with_adopt_home(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            wiki.publish_local(path, {'Home.md': 'Home', 'Module.md': 'Original'}, REPO, REVISION)
            (path / 'Module.md').write_text('Manual improvement')
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Changed', 'Module.md': 'Replacement'}, REPO, REVISION, adopt_home=True)
            self.assertEqual((path / 'Home.md').read_text(), 'Home')
            self.assertEqual((path / 'Module.md').read_text(), 'Manual improvement')

    def test_only_unchanged_previously_owned_pages_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            wiki.publish_local(path, {'Home.md': 'Home', 'Old.md': 'Old'}, REPO, REVISION)
            (path / 'Custom.md').write_text('Unmanaged')
            (path / 'Old.md').write_text('Manual change')
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION)
            (path / 'Old.md').write_text('Old')
            wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION)
            self.assertFalse((path / 'Old.md').exists())
            self.assertTrue((path / 'Custom.md').exists())

    def test_check_mode_is_read_only_and_detects_revision_or_content_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'not-created'
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION, check=True)
            self.assertFalse(path.exists())
            wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION)
            before = {p.name: p.read_bytes() for p in path.iterdir()}
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Changed'}, REPO, 'b' * 40, check=True)
            self.assertEqual(before, {p.name: p.read_bytes() for p in path.iterdir()})

    def test_manifest_paths_symlinks_and_wrong_repository_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION)
            manifest = json.loads((path / wiki.MANIFEST).read_text())
            manifest['pages']['../outside.md'] = 'invalid'
            (path / wiki.MANIFEST).write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION)
            manifest['pages'].pop('../outside.md')
            manifest['repository'] = 'another/repository'
            (path / wiki.MANIFEST).write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION)
            (path / wiki.MANIFEST).unlink()
            (path / 'Home.md').unlink()
            (path / 'Home.md').symlink_to(path / 'elsewhere.md')
            with self.assertRaises(ValueError):
                wiki.publish_local(path, {'Home.md': 'Home'}, REPO, REVISION, adopt_home=True)


if __name__ == '__main__':
    unittest.main()
