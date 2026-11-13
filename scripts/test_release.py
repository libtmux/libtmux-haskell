"""Release identity, archive integrity and partial-upload recovery."""

import gzip
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="libtmux-haskell-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = self.root / "libtmux-haskell.cabal"
        self.manifest.write_text("name: libtmux-haskell\nversion: 0.0.1.0\n")
        (self.root / "cabal.project").write_text("packages: .\nindex-state: 2026-11-06T00:00:00Z\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n\n## 0.0.1.0\n\n- Initial release.\n")
        self.directory = self.root / "release"
        self.directory.mkdir()
        self.source = self.directory / "libtmux-haskell-0.0.1.0.tar.gz"
        self.docs = self.directory / "libtmux-haskell-0.0.1.0-docs.tar.gz"
        self.archive(self.source, {"libtmux-haskell-0.0.1.0/libtmux-haskell.cabal": self.manifest.read_bytes()})
        self.archive(self.docs, {"libtmux-haskell-0.0.1.0-docs/index.html": b"<html>API documentation</html>"})
        self.checksums()

    def archive(self, path, files):
        with tarfile.open(path, "w:gz") as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))

    def checksums(self):
        (self.directory / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
            for path in [self.source, self.docs]
        ))

    def test_tag_must_match_the_numeric_package_version(self):
        self.assertEqual(release.metadata(self.root, "v0.0.1.0"), "0.0.1.0")
        for tag in ["v0.0.2.0", "0.0.1.0", "v0.0.1.0-alpha.1", "master"]:
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "tag"):
                release.metadata(self.root, tag)
        self.manifest.write_text("name: libtmux-haskell\nversion: 0.0.1.0-alpha.1\n")
        with self.assertRaisesRegex(ValueError, "numeric"):
            release.metadata(self.root)

    def test_release_requires_its_own_changelog_entry(self):
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n")
        with self.assertRaisesRegex(ValueError, "changelog"):
            release.metadata(self.root)

    def test_only_the_expected_package_and_unambiguous_version_are_allowed(self):
        for manifest in ["name: other\nversion: 0.0.1.0\n", "name: libtmux-haskell\nversion: 0.0.1.0\nversion: 0.0.2.0\n"]:
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                self.manifest.write_text(manifest)
                release.metadata(self.root)

    def test_both_verified_archives_are_required(self):
        self.assertEqual(release.verify(self.directory, self.root), (self.source, self.docs))
        self.docs.unlink()
        with self.assertRaisesRegex(ValueError, "archive"):
            release.verify(self.directory, self.root)

    def test_changed_bytes_and_wrong_archive_identity_are_rejected(self):
        self.source.write_bytes(self.source.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            release.verify(self.directory, self.root)
        self.archive(self.source, {"other-0.0.1.0/other.cabal": self.manifest.read_bytes()})
        self.checksums()
        with self.assertRaisesRegex(ValueError, "identity"):
            release.verify(self.directory, self.root)

    def test_missing_documentation_index_is_rejected_even_with_valid_checksums(self):
        self.archive(self.docs, {"libtmux-haskell-0.0.1.0-docs/README": b"missing index"})
        self.checksums()
        with self.assertRaisesRegex(ValueError, "index"):
            release.verify(self.directory, self.root)

    def test_prepare_selects_the_whole_core_package_instead_of_its_library_component(self):
        generated = self.root / "dist-newstyle" / self.docs.name
        generated.parent.mkdir()
        generated.write_bytes(self.docs.read_bytes())

        def cabal(command, **kwargs):
            if command[:2] == ["cabal", "sdist"]:
                if command[2] != "pkg:libtmux-haskell":
                    raise subprocess.CalledProcessError(1, command, stderr="Only entire packages may be packaged")
            else:
                self.assertEqual(command, ["cabal", "haddock", "lib:libtmux-haskell", "--haddock-for-hackage", "--offline"])

        with patch.object(subprocess, "run", side_effect=cabal), patch.object(release, "consumer") as consumer:
            release.prepare(self.directory, self.root)
        self.assertEqual(release.verify(self.directory, self.root), (self.source, self.docs))
        consumer.assert_called_once_with(self.source.read_bytes(), self.root, offline=True)

    def test_existing_identical_source_skips_upload_but_repairs_documentation(self):
        source = self.source.read_bytes()
        documentation = gzip.decompress(self.docs.read_bytes())
        with patch.dict(os.environ, {"HACKAGE_AUTH_TOKEN": "test-token"}), \
                patch.object(release, "remote", side_effect=[source, source, documentation]), \
                patch.object(release, "cabal_upload") as upload:
            release.upload(self.directory, self.root, publish=True, tag="v0.0.1.0")
        self.assertEqual(upload.call_args_list, [unittest.mock.call(self.docs, True, True)])

    def test_existing_different_source_stops_before_any_upload(self):
        with patch.dict(os.environ, {"HACKAGE_AUTH_TOKEN": "test-token"}), \
                patch.object(release, "remote", return_value=b"different archive"), \
                patch.object(release, "cabal_upload") as upload:
            with self.assertRaisesRegex(ValueError, "different"):
                release.upload(self.directory, self.root, publish=True, tag="v0.0.1.0")
        upload.assert_not_called()

    def test_candidate_and_published_uploads_verify_the_served_archive_and_docs(self):
        source = self.source.read_bytes()
        documentation = gzip.decompress(self.docs.read_bytes())
        for publish in [False, True]:
            with self.subTest(publish=publish), \
                    patch.dict(os.environ, {"HACKAGE_AUTH_TOKEN": "test-token"}), \
                    patch.object(release, "remote", side_effect=[None, source, documentation]) as remote, \
                    patch.object(release, "cabal_upload") as upload:
                release.upload(self.directory, self.root, publish=publish, tag="v0.0.1.0" if publish else None)
                self.assertEqual(upload.call_args_list, [
                    unittest.mock.call(self.source, publish, False),
                    unittest.mock.call(self.docs, publish, True),
                ])
                base = "https://hackage.haskell.org/package/libtmux-haskell-0.0.1.0"
                if not publish:
                    base += "/candidate"
                self.assertEqual(remote.call_args_list[0].args, (base + "/libtmux-haskell-0.0.1.0.tar.gz",))
                self.assertEqual(remote.call_args_list[-1].args, (base + "/docs.tar",))

    def test_review_changes_can_replace_a_candidate_before_publication(self):
        with patch.dict(os.environ, {"HACKAGE_AUTH_TOKEN": "test-token"}), \
                patch.object(release, "remote", side_effect=[
                    b"previous candidate", self.source.read_bytes(), gzip.decompress(self.docs.read_bytes())]), \
                patch.object(release, "cabal_upload") as upload:
            release.upload(self.directory, self.root)
        self.assertEqual(upload.call_args_list, [
            unittest.mock.call(self.source, False, False), unittest.mock.call(self.docs, False, True)])

    def test_missing_credentials_and_untagged_publication_stop_before_network_access(self):
        with patch.dict(os.environ, {"HACKAGE_AUTH_TOKEN": ""}), patch.object(release, "remote") as remote:
            with self.assertRaisesRegex(ValueError, "HACKAGE_AUTH_TOKEN"):
                release.upload(self.directory, self.root)
        remote.assert_not_called()
        with patch.dict(os.environ, {"HACKAGE_AUTH_TOKEN": "test-token"}), patch.object(release, "remote") as remote:
            with self.assertRaisesRegex(ValueError, "tag"):
                release.upload(self.directory, self.root, publish=True)
        remote.assert_not_called()

    def test_cabal_uses_https_and_never_echoes_the_token_on_failure(self):
        def fail(command, **kwargs):
            config = Path(command[1].removeprefix("--config-file="))
            self.assertIn("url: https://hackage.haskell.org/", config.read_text())
            self.assertIn("--publish", command)
            self.assertIn("--documentation", command)
            return subprocess.CompletedProcess(command, 1, "", "rejected secret-token")
        with patch.dict(os.environ, {"HACKAGE_AUTH_TOKEN": "secret-token"}), \
                patch.object(subprocess, "run", side_effect=fail), \
                self.assertRaisesRegex(ValueError, "rejected") as error:
            release.cabal_upload(self.docs, True, True)
        self.assertNotIn("secret-token", str(error.exception))

    def test_public_consumer_runs_the_declared_example_from_an_external_archive(self):
        example = self.root / "examples/typed-values"
        example.mkdir(parents=True)
        (example / "Main.hs").write_text('main = putStrLn "validated"\n')
        (example / "libtmux-typed-values.cabal").write_text(
            "name: libtmux-typed-values\nexecutable typed-values\n  main-is: Main.hs\n")
        (example / "expected.stdout").write_text("validated\n")
        (example / "README.md").write_text("# Typed values\n")
        program = self.root / "program"
        program.write_text(f'#!{sys.executable}\nprint("validated")\n')
        program.chmod(0o700)
        cabal = self.root / "cabal"
        cabal.write_text(f'''#!{sys.executable}
import pathlib, sys
args = sys.argv[1:]
offline = args[-1:] == ["--offline"]
if args[-1:] == ["--offline"]:
    args = args[:-1]
if args == ["update"]:
    pathlib.Path({str(self.root / 'updated')!r}).write_text("updated")
elif args in [["build", "exe:typed-values"], ["list-bin", "exe:typed-values"]]:
    root = pathlib.Path.cwd()
    assert (root / "source.tar.gz").read_bytes() == b"public source archive"
    assert (root / "Main.hs").is_file()
    assert "packages: . source.tar.gz" in (root / "cabal.project").read_text()
    assert "constraints: libtmux-haskell ==0.0.1.0" in (root / "cabal.project").read_text()
    assert ("index-state: 2026-11-06T00:00:00Z" in (root / "cabal.project").read_text()) == offline
    if args[0] == "list-bin":
        print({str(program)!r})
else:
    sys.exit("unexpected Cabal target: " + repr(args))
''')
        cabal.chmod(0o700)
        with patch.dict(os.environ, {"PATH": str(self.root) + os.pathsep + os.environ["PATH"]}):
            for offline in [False, True]:
                with self.subTest(offline=offline):
                    (self.root / "updated").unlink(missing_ok=True)
                    release.consumer(b"public source archive", self.root, offline=offline)
                    self.assertEqual((self.root / "updated").exists(), not offline)


if __name__ == "__main__":
    unittest.main()
