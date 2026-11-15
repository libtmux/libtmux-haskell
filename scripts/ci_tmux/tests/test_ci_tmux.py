"""Cache reuse and ownership checks using the CI_TEST_TMUX executable.

The tests run ``tmux -V`` on the selected binary and never start a server.
"""

import hashlib
import json
import os
import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest

import ci_tmux

type Install = Callable[[Path, ci_tmux.Identity], None]
type Record = Callable[[Path], None]


@pytest.fixture
def tmux_binary() -> Path:
    """The explicit tmux executable under test."""
    selected = os.environ.get("CI_TEST_TMUX")
    if not selected:
        pytest.fail("Set CI_TEST_TMUX to the tmux executable the cache tests copy")
    return Path(selected).resolve()


@pytest.fixture
def identity(tmux_binary: Path) -> ci_tmux.Identity:
    """A build identity naming the selected binary's version."""
    reported = subprocess.check_output([tmux_binary, "-V"], text=True)
    return {
        "version": reported.strip().removeprefix("tmux "),
        "source": "pinned-source",
        "image": "runner-image",
        "compiler": "compiler",
        "packages": "libraries",
        "recipe": "recipe",
        "arch": "x86_64",
    }


@pytest.fixture
def install(tmux_binary: Path) -> Install:
    """A builder that installs a copy of the selected binary under ``prefix``."""

    def copy(prefix: Path, identity: ci_tmux.Identity) -> None:
        (prefix / "bin").mkdir(parents=True)
        shutil.copy2(tmux_binary, prefix / "bin/tmux")

    return copy


@pytest.fixture
def record(identity: ci_tmux.Identity) -> Record:
    """Write the build record that vouches for the binary under ``prefix``."""

    def write(prefix: Path) -> None:
        digest = hashlib.sha256((prefix / "bin/tmux").read_bytes()).hexdigest()
        (prefix / "build.json").write_text(json.dumps({"identity": identity, "sha256": digest}))

    return write


@pytest.fixture
def prefix(tmp_path: Path) -> Path:
    """The cache directory a test owns; it does not exist yet."""
    return tmp_path / "owned"


def test_valid_hit_does_not_rebuild_or_replace_the_binary(
    prefix: Path, identity: ci_tmux.Identity, install: Install, record: Record
) -> None:
    """A cache whose record, hash and version match is reused as is."""
    install(prefix, identity)
    record(prefix)
    inode = (prefix / "bin/tmux").stat().st_ino

    def unexpected(*_: object) -> None:
        pytest.fail("valid cache was rebuilt")

    assert not ci_tmux.prepare(prefix, identity, unexpected)
    assert ci_tmux.valid(prefix, identity)
    assert (prefix / "bin/tmux").stat().st_ino == inode


@pytest.mark.parametrize("fault", ["identity", "hash", "loader", "metadata"])
def test_invalid_identity_hash_loader_and_metadata_are_rebuilt(
    tmp_path: Path,
    identity: ci_tmux.Identity,
    install: Install,
    record: Record,
    fault: str,
) -> None:
    """A record, hash, executable or metadata fault forces a rebuild that then validates."""
    prefix = tmp_path / fault
    install(prefix, identity)
    record(prefix)
    build_record = json.loads((prefix / "build.json").read_text())
    if fault == "identity":
        build_record["identity"]["source"] = "other"
        (prefix / "build.json").write_text(json.dumps(build_record))
    elif fault == "hash":
        with (prefix / "bin/tmux").open("ab") as output:
            output.write(b"changed")
    elif fault == "loader":
        (prefix / "bin/tmux").write_text("#!/bin/sh\nexit 127\n")
        record(prefix)
    else:
        (prefix / "build.json").write_text("{")
    assert not ci_tmux.valid(prefix, identity)
    assert ci_tmux.prepare(prefix, identity, install)
    assert ci_tmux.valid(prefix, identity)


def test_symlink_cache_does_not_remove_its_target(
    tmp_path: Path,
    prefix: Path,
    tmux_binary: Path,
    identity: ci_tmux.Identity,
    install: Install,
    record: Record,
) -> None:
    """Replacing a symlinked cache leaves the directory it pointed at alone."""
    borrowed = tmp_path / "borrowed"
    install(borrowed, identity)
    record(borrowed)
    prefix.symlink_to(borrowed, target_is_directory=True)
    assert ci_tmux.prepare(prefix, identity, install)
    assert not prefix.is_symlink()
    assert (borrowed / "bin/tmux").read_bytes() == tmux_binary.read_bytes()


def test_failed_build_cannot_publish_a_cache_record(
    prefix: Path, identity: ci_tmux.Identity
) -> None:
    """A build that raises leaves no record that would vouch for its partial output."""

    def broken(prefix: Path, identity: ci_tmux.Identity) -> None:
        prefix.mkdir()
        raise RuntimeError("compiler failed")

    with pytest.raises(RuntimeError, match="compiler failed"):
        ci_tmux.prepare(prefix, identity, broken)
    assert not (prefix / "build.json").exists()


def test_symlinked_cache_parent_cannot_remove_borrowed_children(
    tmp_path: Path, identity: ci_tmux.Identity, install: Install
) -> None:
    """A cache under a symlinked parent is refused before anything is removed."""
    version = tmp_path / "borrowed/3.3"
    version.mkdir(parents=True)
    marker = version / "keep"
    marker.write_text("borrowed")
    parent = tmp_path / "cache"
    parent.symlink_to(tmp_path / "borrowed", target_is_directory=True)
    with pytest.raises(ValueError, match="cache ancestor"):
        ci_tmux.prepare(parent / "3.3", identity, install)
    assert marker.read_text() == "borrowed"


@pytest.mark.parametrize(
    "field", ["version", "source", "image", "compiler", "packages", "recipe", "arch"]
)
def test_each_build_identity_change_invalidates_the_key(
    identity: ci_tmux.Identity, field: str
) -> None:
    """Changing any part of the build identity names a different cache entry."""
    changed = {**identity, field: identity[field] + "-changed"}
    assert ci_tmux.cache_key(identity) != ci_tmux.cache_key(changed)
