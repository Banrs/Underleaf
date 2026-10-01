"""Run with: python3 -m unittest discover -s scripts -p 'test_texpresso_probe.py'."""

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "texpresso_probe", Path(__file__).with_name("texpresso-probe.py"))
probe_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe_module)


FAKE_CHILD = """
import json, os, sys, time
from pathlib import Path
Path(sys.argv[-1]).with_suffix('.pid').write_text(str(os.getpid()))
print(json.dumps(['append-lines', 'out', 'initial']), flush=True)
print(json.dumps(['flush']), flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command[0] == 'open':
        continue
    elif command[0] == 'change':
        if command[2:5] != [len('α '.encode()), len('Hello'.encode()), 'Hi']:
            sys.exit(4)
        if os.environ.get('FAKE_HANG'):
            time.sleep(30)
        print(json.dumps(['truncate-lines', 'out', 0]), flush=True)
        print(json.dumps(['append-lines', 'out', 'edited']), flush=True)
        print(json.dumps(['flush']), flush=True)
"""


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "main.tex"
        self.root.write_text("α Hello", encoding="utf-8")
        self.fake = Path(self.tmp.name) / "fake.py"
        self.fake.write_text(FAKE_CHILD)

    def test_sends_utf8_byte_edit_and_receives_flush(self):
        result = probe_module.probe([sys.executable, str(self.fake)],
                                    self.root, "Hello", "Hi", 2, 2)
        self.assertIn("append-lines", result["edit_events"])
        self.assertGreaterEqual(result["edit_flush_ms"], 0)
        self.assertIsNotNone(result["edit_first_output_ms"])

    def test_timeout_reaps_child(self):
        prior = os.environ.get("FAKE_HANG")
        os.environ["FAKE_HANG"] = "1"
        try:
            with self.assertRaisesRegex(RuntimeError, "deadline"):
                probe_module.probe([sys.executable, str(self.fake)],
                                   self.root, "Hello", "Hi", 2, 0.1)
        finally:
            if prior is None:
                os.environ.pop("FAKE_HANG", None)
            else:
                os.environ["FAKE_HANG"] = prior
        pid = int(self.root.with_suffix(".pid").read_text())
        if os.name != "nt":
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
