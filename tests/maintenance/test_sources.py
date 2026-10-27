import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'maintenance'))
from pman_maintenance.sources import check_reference

class SourcesTest(unittest.TestCase):
    def setUp(self): self.ref = {'repository': 'community-scripts/ProxmoxVE', 'path': 'tools/pve/fstrim.sh', 'blob_sha': 'abc'}
    def test_unchanged(self):
        result = check_reference(self.ref, lambda url, etag: (200, [{'name': 'fstrim.sh', 'type': 'file', 'sha': 'abc'}], 'tag'))
        self.assertEqual(result['status'], 'geprüfter Stand')
    def test_changed(self):
        self.assertEqual(check_reference(self.ref, lambda *a: (200, [{'name': 'fstrim.sh', 'type': 'file', 'sha': 'def'}], ''))['status'], 'Upstream geändert')
    def test_missing(self):
        self.assertEqual(check_reference(self.ref, lambda *a: (404, {}, ''))['status'], 'Quelle fehlt')
    def test_rate_limit_not_current(self):
        self.assertEqual(check_reference(self.ref, lambda *a: (403, {}, ''))['status'], 'Prüfung fehlgeschlagen')
    def test_timeout_not_current(self):
        def timeout(*args): raise TimeoutError()
        self.assertEqual(check_reference(self.ref, timeout)['status'], 'Prüfung fehlgeschlagen')
    def test_304_requires_cached_success(self):
        result = check_reference(self.ref, lambda *a: (304, {}, ''))
        self.assertEqual(result['status'], 'Prüfung fehlgeschlagen')

if __name__ == '__main__': unittest.main()

class CacheTest(unittest.TestCase):
    def test_cached_304_unchanged(self):
        result = check_reference({'repository':'r/r','path':'a/b','blob_sha':'abc'}, lambda *a:(304,{},''), {'observed_sha':'abc','etag':'tag'})
        self.assertEqual(result['status'],'geprüfter Stand')
    def test_cached_304_changed(self):
        result = check_reference({'repository':'r/r','path':'a/b','blob_sha':'abc'}, lambda *a:(304,{},''), {'observed_sha':'def','etag':'tag'})
        self.assertEqual(result['status'],'Upstream geändert')
    def test_missing_file_in_directory_listing(self):
        result = check_reference({'repository':'r/r','path':'a/b','blob_sha':'abc'}, lambda *a:(200,[],''))
        self.assertEqual(result['status'],'Quelle fehlt')
    def test_malformed_metadata_fails(self):
        result = check_reference({'repository':'r/r','path':'a/b','blob_sha':'abc'}, lambda *a:(200,{'content':'must not request file contents'},''))
        self.assertEqual(result['status'],'Prüfung fehlgeschlagen')

class MalformedTest(unittest.TestCase):
    def test_missing_sha_does_not_crash(self):
        result = check_reference({'repository':'r/r','path':'a/b','blob_sha':'abc'}, lambda *a:(200,[{'name':'b','type':'file'}],''))
        self.assertEqual(result['status'],'Prüfung fehlgeschlagen')
