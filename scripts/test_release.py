"""Release identity, archive integrity, authentication errors and partial-upload recovery."""

import gzip
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
from unittest.mock import Mock

import pytest

import release

SOURCE = "libtmux-haskell-0.0.1.0.tar.gz"
DOCS = "libtmux-haskell-0.0.1.0-docs.tar.gz"


def write_archive(path, files):
    with tarfile.open(path, "w:gz") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))


def write_checksums(directory):
    (directory / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n"
        for name in [SOURCE, DOCS]
    ))


@pytest.fixture
def release_root(tmp_path):
    (tmp_path / "libtmux-haskell.cabal").write_text("name: libtmux-haskell\nversion: 0.0.1.0\n")
    (tmp_path / "cabal.project").write_text("packages: .\nindex-state: 2026-11-06T00:00:00Z\n")
    (tmp_path / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n\n## 0.0.1.0\n\n- Initial release.\n")
    return tmp_path


@pytest.fixture
def release_directory(release_root):
    directory = release_root / "release"
    directory.mkdir()
    write_archive(directory / SOURCE, {
        "libtmux-haskell-0.0.1.0/libtmux-haskell.cabal": (release_root / "libtmux-haskell.cabal").read_bytes(),
    })
    write_archive(directory / DOCS, {"libtmux-haskell-0.0.1.0-docs/LibTmux.html": b"<html>API documentation</html>"})
    write_checksums(directory)
    return directory


@pytest.fixture
def upload_account(monkeypatch):
    monkeypatch.setenv("HACKAGE_AUTH_TOKEN", "test-token")


@pytest.mark.parametrize("tag", ["v0.0.2.0", "0.0.1.0", "v0.0.1.0-alpha.1", "master"])
def test_tag_must_match_the_numeric_package_version(release_root, tag):
    assert release.metadata(release_root, "v0.0.1.0") == "0.0.1.0"
    with pytest.raises(ValueError, match="tag"):
        release.metadata(release_root, tag)


@pytest.mark.parametrize("manifest, error", [
    ("name: other\nversion: 0.0.1.0\n", "package name"),
    ("name: libtmux-haskell\nversion: 0.0.1.0\nversion: 0.0.2.0\n", "version"),
    ("name: libtmux-haskell\nversion: 0.0.1.0-alpha.1\n", "numeric"),
])
def test_invalid_package_identity_is_rejected(release_root, manifest, error):
    (release_root / "libtmux-haskell.cabal").write_text(manifest)
    with pytest.raises(ValueError, match=error):
        release.metadata(release_root)


def test_release_requires_its_own_changelog_entry(release_root):
    (release_root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n")
    with pytest.raises(ValueError, match="changelog"):
        release.metadata(release_root)


def test_both_verified_archives_are_required(release_root, release_directory):
    assert release.verify(release_directory, release_root) == (release_directory / SOURCE, release_directory / DOCS)
    (release_directory / DOCS).unlink()
    with pytest.raises(ValueError, match="archive"):
        release.verify(release_directory, release_root)


def test_changed_bytes_and_wrong_archive_identity_are_rejected(release_root, release_directory):
    source = release_directory / SOURCE
    source.write_bytes(source.read_bytes() + b"changed")
    with pytest.raises(ValueError, match="checksum"):
        release.verify(release_directory, release_root)
    write_archive(source, {"other-0.0.1.0/other.cabal": b"name: other\n"})
    write_checksums(release_directory)
    with pytest.raises(ValueError, match="identity"):
        release.verify(release_directory, release_root)


def test_missing_public_module_documentation_is_rejected(release_root, release_directory):
    write_archive(release_directory / DOCS, {"libtmux-haskell-0.0.1.0-docs/index.html": b"no public API docs"})
    write_checksums(release_directory)
    with pytest.raises(ValueError, match="LibTmux.html"):
        release.verify(release_directory, release_root)


def test_prepare_selects_the_whole_core_package(release_root, release_directory, monkeypatch):
    generated = release_root / "dist-newstyle" / DOCS
    generated.parent.mkdir()
    generated.write_bytes((release_directory / DOCS).read_bytes())

    def cabal(command, **kwargs):
        if command[:2] == ["cabal", "sdist"]:
            assert command[2] == "pkg:libtmux-haskell"
        else:
            assert command == ["cabal", "haddock", "lib:libtmux-haskell", "--haddock-for-hackage", "--offline"]

    consumer = Mock()
    monkeypatch.setattr(subprocess, "run", cabal)
    monkeypatch.setattr(release, "consumer", consumer)
    release.prepare(release_directory, release_root)
    assert release.verify(release_directory, release_root) == (release_directory / SOURCE, release_directory / DOCS)
    consumer.assert_called_once_with((release_directory / SOURCE).read_bytes(), release_root, offline=True)


def test_identical_source_skips_upload_but_repairs_documentation(
    release_root, release_directory, upload_account, monkeypatch,
):
    source = (release_directory / SOURCE).read_bytes()
    documentation = gzip.decompress((release_directory / DOCS).read_bytes())
    monkeypatch.setattr(release, "remote", Mock(side_effect=[source, source, documentation]))
    upload = Mock()
    monkeypatch.setattr(release, "cabal_upload", upload)
    release.upload(release_directory, release_root, publish=True, tag="v0.0.1.0")
    upload.assert_called_once_with(release_directory / DOCS, True, True)


def test_different_published_source_stops_before_upload(release_root, release_directory, upload_account, monkeypatch):
    monkeypatch.setattr(release, "remote", lambda url: b"different archive")
    upload = Mock()
    monkeypatch.setattr(release, "cabal_upload", upload)
    with pytest.raises(ValueError, match="different"):
        release.upload(release_directory, release_root, publish=True, tag="v0.0.1.0")
    upload.assert_not_called()


@pytest.mark.parametrize("publish", [False, True])
def test_candidate_and_published_uploads_verify_served_archives(
    release_root, release_directory, upload_account, monkeypatch, publish,
):
    source = (release_directory / SOURCE).read_bytes()
    documentation = gzip.decompress((release_directory / DOCS).read_bytes())
    remote = Mock(side_effect=[None, source, documentation])
    upload = Mock()
    monkeypatch.setattr(release, "remote", remote)
    monkeypatch.setattr(release, "cabal_upload", upload)
    release.upload(release_directory, release_root, publish=publish, tag="v0.0.1.0" if publish else None)
    assert [call.args for call in upload.call_args_list] == [
        (release_directory / SOURCE, publish, False), (release_directory / DOCS, publish, True),
    ]
    base = "https://hackage.haskell.org/package/libtmux-haskell-0.0.1.0"
    if not publish:
        base += "/candidate"
    assert remote.call_args_list[0].args == (base + "/" + SOURCE,)
    assert remote.call_args_list[-1].args == (base + "/docs.tar",)


def test_review_changes_can_replace_a_candidate(release_root, release_directory, upload_account, monkeypatch):
    monkeypatch.setattr(release, "remote", Mock(side_effect=[
        b"previous candidate", (release_directory / SOURCE).read_bytes(),
        gzip.decompress((release_directory / DOCS).read_bytes()),
    ]))
    upload = Mock()
    monkeypatch.setattr(release, "cabal_upload", upload)
    release.upload(release_directory, release_root)
    assert [call.args for call in upload.call_args_list] == [
        (release_directory / SOURCE, False, False), (release_directory / DOCS, False, True),
    ]


@pytest.mark.parametrize("token, publish, error", [("", False, "HACKAGE_AUTH_TOKEN"), ("test-token", True, "tag")])
def test_missing_credentials_and_untagged_publication_stop_before_network(
    release_root, release_directory, monkeypatch, token, publish, error,
):
    monkeypatch.setenv("HACKAGE_AUTH_TOKEN", token)
    remote = Mock()
    monkeypatch.setattr(release, "remote", remote)
    with pytest.raises(ValueError, match=error):
        release.upload(release_directory, release_root, publish=publish)
    remote.assert_not_called()


@pytest.mark.parametrize("status, guidance", [(401, "HACKAGE_AUTH_TOKEN"), (403, "uploaders group"), (500, "exit 1")])
def test_cabal_failure_uses_https_and_redacts_tokens(release_directory, monkeypatch, status, guidance):
    def fail(command, **kwargs):
        config = Path(command[1].removeprefix("--config-file="))
        assert "url: https://hackage.haskell.org/" in config.read_text()
        assert "--publish" in command
        assert "--documentation" in command
        return subprocess.CompletedProcess(command, 1, "", f"http code {status}\nrejected secret-token")

    monkeypatch.setenv("HACKAGE_AUTH_TOKEN", "secret-token")
    monkeypatch.setattr(subprocess, "run", fail)
    with pytest.raises(ValueError, match=guidance) as error:
        release.cabal_upload(release_directory / DOCS, True, True)
    assert "secret-token" not in str(error.value)


@pytest.fixture
def external_consumer(release_root, monkeypatch):
    example = release_root / "examples/typed-values"
    example.mkdir(parents=True)
    (example / "Main.hs").write_text('main = putStrLn "validated"\n')
    (example / "libtmux-typed-values.cabal").write_text(
        "name: libtmux-typed-values\nexecutable typed-values\n  main-is: Main.hs\n")
    (example / "expected.stdout").write_text("validated\n")
    (example / "README.md").write_text("# Typed values\n")
    program = release_root / "program"
    program.write_text(f'#!{sys.executable}\nprint("validated")\n')
    program.chmod(0o700)
    cabal = release_root / "cabal"
    cabal.write_text(f'''#!{sys.executable}
import pathlib, sys
args = sys.argv[1:]
offline = args[-1:] == ["--offline"]
if offline:
    args = args[:-1]
if args == ["update"]:
    pathlib.Path({str(release_root / 'updated')!r}).write_text("updated")
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
    monkeypatch.setenv("PATH", str(release_root) + os.pathsep + os.environ["PATH"])


@pytest.mark.parametrize("offline", [False, True])
def test_public_consumer_executes_external_archive(release_root, external_consumer, offline):
    release.consumer(b"public source archive", release_root, offline=offline)
    assert (release_root / "updated").exists() is not offline
