import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "tools/call_index.py"
spec = importlib.util.spec_from_file_location("call_index", path)
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)


class IndexTests(unittest.TestCase):
    def test_named_calls_not_the_intro_count(self):
        calls = index.public_names(index.INDEX.read_text())
        self.assertEqual((len(calls), len(set(calls))), (135, 135))
        self.assertIn("File.read", calls)
        self.assertIn("File.write", calls)
        self.assertIn("Job.setPolicy", calls)

    def test_malformed_source_rejected_before_writing(self):
        document = index.INDEX.read_text()
        for old, new in [("Port (4)", "Port (5)"), ("Port.post,", "Port-post,")]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                index.public_names(document.replace(old, new))

    def test_collision_rejected(self):
        for names in [["Test.go", "Test.go"], ["Ab.cdEf", "AbCd.ef"]]:
            with self.assertRaises(ValueError):
                index.catalogue(names[:1], names[1:])

    def test_namespaces_do_not_shift(self):
        self.assertEqual(index.catalogue(["Z.go", "A.go"], ["C.go", "B.go"]),
                         [(1, "aGo"), (2, "zGo"), (65536, "bGo"), (65537, "cGo")])

    def test_both_sides_current(self):
        extra = [s for s in index.EXTENSIONS.read_text().splitlines() if s and s[0] != "#"]
        calls = index.catalogue(index.public_names(index.INDEX.read_text()), extra)
        for i, output in enumerate(index.OUTPUTS):
            self.assertEqual(output.read_text(), index.render(calls, kernel=i == 0))


if __name__ == "__main__":
    unittest.main()
