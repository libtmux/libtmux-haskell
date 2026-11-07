"""Critical cache reuse and ownership checks; no network or compilation."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import ci_tmux


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="libtmux-haskell-cache-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prefix = self.root / "owned"
        self.binary = Path(os.environ["CI_TEST_TMUX"]).resolve()
        version = subprocess.check_output([self.binary, "-V"], text=True).strip().removeprefix("tmux ")
        self.identity = {"version": version, "source": "pinned-source", "image": "runner-image",
                         "compiler": "compiler", "packages": "libraries", "recipe": "recipe", "arch": "x86_64"}

    def install(self, prefix, identity):
        (prefix / "bin").mkdir(parents=True)
        shutil.copy2(self.binary, prefix / "bin/tmux")

    def record(self, prefix):
        (prefix / "build.json").write_text(json.dumps({"identity": self.identity,
            "sha256": hashlib.sha256((prefix / "bin/tmux").read_bytes()).hexdigest()}))

    def test_valid_hit_does_not_rebuild_or_replace_the_binary(self):
        self.install(self.prefix, self.identity)
        self.record(self.prefix)
        inode = (self.prefix / "bin/tmux").stat().st_ino
        def unexpected(*_):
            self.fail("valid cache was rebuilt")
        self.assertFalse(ci_tmux.prepare(self.prefix, self.identity, unexpected))
        self.assertTrue(ci_tmux.valid(self.prefix, self.identity))
        self.assertEqual((self.prefix / "bin/tmux").stat().st_ino, inode)

    def test_invalid_identity_hash_loader_and_metadata_are_rebuilt(self):
        for fault in ["identity", "hash", "loader", "metadata"]:
            with self.subTest(fault=fault):
                prefix = self.root / fault
                self.install(prefix, self.identity)
                self.record(prefix)
                record = json.loads((prefix / "build.json").read_text())
                if fault == "identity":
                    record["identity"]["source"] = "other"
                    (prefix / "build.json").write_text(json.dumps(record))
                elif fault == "hash":
                    with (prefix / "bin/tmux").open("ab") as output:
                        output.write(b"changed")
                elif fault == "loader":
                    (prefix / "bin/tmux").write_text("#!/bin/sh\nexit 127\n")
                    self.record(prefix)
                else:
                    (prefix / "build.json").write_text("{")
                self.assertTrue(ci_tmux.prepare(prefix, self.identity, self.install))
                self.assertTrue(ci_tmux.valid(prefix, self.identity))

    def test_symlink_cache_does_not_remove_its_target(self):
        borrowed = self.root / "borrowed"
        self.install(borrowed, self.identity)
        self.record(borrowed)
        self.prefix.symlink_to(borrowed, target_is_directory=True)
        self.assertTrue(ci_tmux.prepare(self.prefix, self.identity, self.install))
        self.assertFalse(self.prefix.is_symlink())
        self.assertEqual((borrowed / "bin/tmux").read_bytes(), self.binary.read_bytes())

    def test_failed_build_cannot_publish_a_cache_record(self):
        def broken(prefix, identity):
            prefix.mkdir()
            raise RuntimeError("compiler failed")
        with self.assertRaisesRegex(RuntimeError, "compiler failed"):
            ci_tmux.prepare(self.prefix, self.identity, broken)
        self.assertFalse((self.prefix / "build.json").exists())

    def test_symlinked_cache_parent_cannot_remove_borrowed_children(self):
        borrowed = self.root / "borrowed"
        version = borrowed / "3.3"
        version.mkdir(parents=True)
        marker = version / "keep"
        marker.write_text("borrowed")
        parent = self.root / "cache"
        parent.symlink_to(borrowed, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "cache ancestor"):
            ci_tmux.prepare(parent / "3.3", self.identity, self.install)
        self.assertEqual(marker.read_text(), "borrowed")

    def test_each_build_identity_change_invalidates_the_key(self):
        for field in self.identity:
            with self.subTest(field=field):
                changed = dict(self.identity)
                changed[field] += "-changed"
                self.assertNotEqual(ci_tmux.cache_key(self.identity), ci_tmux.cache_key(changed))


if __name__ == "__main__":
    unittest.main()
