"""Archive-member and Haddock-example checks that need no Cabal build."""

import io
import json
import tarfile
from pathlib import Path
from typing import Any

import pytest

import check_sdist

PLAN = {
    "install-plan": [
        {"id": "base-4.22", "pkg-name": "base"},
        {"id": "libtmux-haskell-0.0.1.0-inplace", "pkg-name": "libtmux-haskell"},
    ]
}


def write_tar(path: Path, files: dict[str, bytes], *, unsafe: str | None = None) -> None:
    """Write an archive of ``files``, plus an empty member named ``unsafe``."""
    with tarfile.open(path, "w:gz") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        if unsafe is not None:
            archive.addfile(tarfile.TarInfo(unsafe))


@pytest.fixture
def checkout(tmp_path: Path) -> Path:
    """A checkout with one source file."""
    root = tmp_path / "checkout"
    (root / "src").mkdir(parents=True)
    (root / "src/LibTmux.hs").write_bytes(b"module LibTmux where\n")
    return root


def verify(tmp_path: Path, root: Path, files: dict[str, bytes], unsafe: str | None = None) -> None:
    """Run the member check on an archive of ``files``."""
    archive = tmp_path / "source.tar.gz"
    write_tar(archive, files, unsafe=unsafe)
    with tarfile.open(archive) as source:
        check_sdist.verify_members(source, root)


def test_archive_members_must_equal_their_checkout_files(tmp_path: Path, checkout: Path) -> None:
    """An archive whose bytes match the checkout passes; a changed member fails."""
    verify(
        tmp_path, checkout, {"libtmux-haskell-0.0.1.0/src/LibTmux.hs": b"module LibTmux where\n"}
    )
    with pytest.raises(ValueError, match=r"differs from source: LibTmux\.hs"):
        verify(tmp_path, checkout, {"libtmux-haskell-0.0.1.0/src/LibTmux.hs": b"changed\n"})


@pytest.mark.parametrize("name", ["../escape.hs", "/etc/passwd"])
def test_unsafe_archive_member_names_are_rejected(
    tmp_path: Path, checkout: Path, name: str
) -> None:
    """Members that leave the archive root are never compared or read."""
    with pytest.raises(ValueError, match="Unsafe"):
        verify(tmp_path, checkout, {}, unsafe=name)


def test_haddock_example_directives_are_limited_to_overloaded_strings() -> None:
    """Only the one setup directive the archive consumer understands is accepted."""
    modules = ["LibTmux"]
    ok = [(":set -XOverloadedStrings", ""), ('parseWindowId "@1"', "Right (WindowId 1)\n")]
    command = check_sdist.haddock_command(PLAN, modules, ok)
    assert command[command.index("-package-id") + 1] == "base-4.22"
    assert command.count("-e") == 3
    with pytest.raises(ValueError, match="Unknown Haddock setup directive"):
        check_sdist.haddock_command(PLAN, modules, [(":set -XCPP", "")])


@pytest.mark.parametrize(
    "plan",
    [
        {"install-plan": [PLAN["install-plan"][0]]},
        {"install-plan": [*PLAN["install-plan"], {"id": "base-4.23", "pkg-name": "base"}]},
    ],
)
def test_haddock_examples_need_one_exact_base_and_library_unit(plan: dict[str, Any]) -> None:
    """A plan with a missing or ambiguous unit is refused instead of guessed."""
    with pytest.raises(ValueError, match="one exact base/library unit"):
        check_sdist.haddock_command(plan, ["LibTmux"], [("1 + 1", "2\n")])


def test_no_executable_haddock_example_is_an_error(tmp_path: Path) -> None:
    """A library whose documentation holds no runnable example fails the check."""
    (tmp_path / "dist-newstyle/cache").mkdir(parents=True)
    (tmp_path / "dist-newstyle/cache/plan.json").write_text(json.dumps(PLAN))
    for examples in [[], [(":set -XOverloadedStrings", "")]]:
        with pytest.raises(ValueError, match="No executable Haddock examples"):
            check_sdist.check_haddock_examples(tmp_path, ["LibTmux"], examples)


@pytest.mark.parametrize(
    "project",
    [
        "packages: .\n",
        f"  tag: {'a1' * 20}\n  tag: {'b2' * 20}\n",
        f"  tag: {'A1' * 20}\n",
        f"  tag: {'a1' * 19}\n",
    ],
)
def test_installation_must_name_exactly_one_full_source_revision(project: str) -> None:
    """No pin, two pins, an uppercase or a short revision are all refused."""
    with pytest.raises(ValueError, match="one reviewed source revision"):
        check_sdist.installation_pin(project)
