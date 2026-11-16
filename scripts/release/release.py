# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Prepare, verify and upload the core package and Haddock documentation."""

import argparse
import gzip
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "libtmux-haskell"

# Seconds. Every external command is bounded so a hang fails with the command's
# name before the job's time limit stops it without one.
QUICK = 120
BUILD = 600


def metadata(root: Path, tag: str | None = None) -> str:
    manifest = (root / f"{PACKAGE}.cabal").read_text()
    names = re.findall(r"^name:\s*(\S+)\s*$", manifest, re.MULTILINE)
    versions = re.findall(r"^version:\s*(\S+)\s*$", manifest, re.MULTILINE)
    if names != [PACKAGE] or len(versions) != 1:
        raise ValueError("Release needs one libtmux-haskell package name and version")
    version = versions[0]
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2,}", version):
        raise ValueError("Release version must have at least three numeric components")
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"Release tag must be v{version}")
    if f"## {version}" not in (root / "CHANGELOG.md").read_text().splitlines():
        raise ValueError(f"Release changelog needs a ## {version} entry")
    return version


def check(
    root: Path, publish: bool = False, tag: str | None = None, require_token: bool = False
) -> str:
    """Return the Cabal version after the checks a candidate or a publication needs.

    A publication needs a tag that matches the version and is part of ``origin/master``.
    A candidate may run from any ref. ``require_token`` adds the upload credential.
    """
    version = metadata(root, tag)
    if publish:
        if tag is None:
            raise ValueError(
                "Publication requires a version tag; use publish=false for a candidate"
            )
        merged = subprocess.run(
            ["git", "merge-base", "--is-ancestor", "HEAD", "origin/master"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
            timeout=QUICK,
        )
        if merged.returncode == 1:
            raise ValueError("Publication requires a tagged commit that is part of master")
        if merged.returncode:
            raise ValueError(f"git merge-base failed (exit {merged.returncode}): {merged.stderr}")
    if require_token:
        token()
    return version


def token() -> str:
    """Return the Hackage token, or explain where to set it."""
    value = os.environ.get("HACKAGE_AUTH_TOKEN")
    if not value:
        raise ValueError(
            "Set HACKAGE_AUTH_TOKEN in the hackage environment; see .github/RELEASE.md"
        )
    return value


def verify(directory: Path, root: Path) -> tuple[Path, Path]:
    version = metadata(root)
    identifier = f"{PACKAGE}-{version}"
    source = directory / f"{identifier}.tar.gz"
    docs = directory / f"{identifier}-docs.tar.gz"
    if not source.is_file() or not docs.is_file():
        raise ValueError("Both source and documentation release archives are required")
    expected = "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in [source, docs]
    )
    if (
        not (directory / "SHA256SUMS").is_file()
        or (directory / "SHA256SUMS").read_text() != expected
    ):
        raise ValueError("Release archive checksum mismatch")
    with tarfile.open(source) as archive:
        try:
            manifest = archive.extractfile(f"{identifier}/{PACKAGE}.cabal")
            if manifest is None or manifest.read() != (root / f"{PACKAGE}.cabal").read_bytes():
                raise ValueError("Source archive identity differs from the checkout")
        except KeyError as error:
            raise ValueError("Source archive identity differs from the checkout") from error
    with tarfile.open(docs) as archive:
        try:
            module = archive.extractfile(f"{identifier}-docs/LibTmux.html")
            if module is None or not module.read():
                raise ValueError("Documentation archive needs a nonempty LibTmux.html")
        except KeyError as error:
            raise ValueError("Documentation archive needs LibTmux.html") from error
    return source, docs


def prepare(directory: Path, root: Path) -> None:
    version = metadata(root)
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["cabal", "sdist", f"pkg:{PACKAGE}", f"--output-directory={directory}"],
        cwd=root,
        check=True,
        timeout=QUICK,
    )
    subprocess.run(
        ["cabal", "haddock", f"lib:{PACKAGE}", "--haddock-for-hackage", "--offline"],
        cwd=root,
        check=True,
        timeout=BUILD,
    )
    docs = root / "dist-newstyle" / f"{PACKAGE}-{version}-docs.tar.gz"
    shutil.copy2(docs, directory / docs.name)
    source = directory / f"{PACKAGE}-{version}.tar.gz"
    (directory / "SHA256SUMS").write_text(
        "".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
            for path in [source, directory / docs.name]
        )
    )
    verify(directory, root)
    consumer(source.read_bytes(), root, offline=True)
    print("PASS: source and Haddock release archives")


def remote(url: str) -> bytes | None:
    request = Request(
        url + "?release_check=" + uuid.uuid4().hex,
        headers={"User-Agent": "libtmux-haskell-release", "Cache-Control": "no-cache"},
    )
    try:
        with urlopen(request, timeout=30) as response:
            return response.read()
    except HTTPError as error:
        if error.code == 404:
            return None
        raise ValueError(f"Hackage verification returned HTTP {error.code}") from error


def cabal_upload(path: Path, publish: bool, documentation: bool) -> None:
    secret = token()
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-upload-") as temporary:
        config = Path(temporary) / "config"
        config.write_text(
            "repository hackage.haskell.org\n  url: https://hackage.haskell.org/\n  secure: True\n"
        )
        command = ["cabal", f"--config-file={config}", "upload", f"--token={secret}"]
        if publish:
            command.append("--publish")
        if documentation:
            command.append("--documentation")
        command.append(str(path))
        try:
            result = subprocess.run(
                command, check=False, capture_output=True, text=True, timeout=QUICK
            )
        except subprocess.TimeoutExpired:
            # The exception would print the argv, which carries the token.
            raise ValueError(f"cabal upload timed out after {QUICK} s") from None
    output = (result.stdout + result.stderr).replace(secret, "[redacted]")
    if result.returncode:
        status = re.search(r"\bhttp code (401|403)\b", output, re.IGNORECASE)
        if status and status[1] == "401":
            raise ValueError(
                "Hackage HTTP 401: HACKAGE_AUTH_TOKEN was rejected; replace the token "
                "in the hackage environment; see .github/RELEASE.md.\n" + output
            )
        if status and status[1] == "403":
            raise ValueError(
                "Hackage HTTP 403: access refused; check the token owner's uploaders group "
                "membership and package maintainer rights; see .github/RELEASE.md.\n" + output
            )
        raise ValueError(f"Hackage upload failed (exit {result.returncode}): {output}")
    print(output, end="")


def redacted(message: str) -> str:
    """Return ``message`` with the Hackage token, if one is set, replaced."""
    secret = os.environ.get("HACKAGE_AUTH_TOKEN")
    return message.replace(secret, "[redacted]") if secret else message


def upload(directory: Path, root: Path, publish: bool = False, tag: str | None = None) -> bytes:
    if publish and tag is None:
        raise ValueError("Publishing requires a matching version tag")
    version = metadata(root, tag)
    source, docs = verify(directory, root)
    token()
    base = f"https://hackage.haskell.org/package/{PACKAGE}-{version}"
    if not publish:
        base += "/candidate"
    url = f"{base}/{source.name}"
    existing = remote(url)
    if publish and existing is not None and existing != source.read_bytes():
        raise ValueError(
            "Hackage already serves different source bytes; do not overwrite this version"
        )
    if existing != source.read_bytes():
        cabal_upload(source, publish, False)
    served = remote(url)
    if served != source.read_bytes():
        raise ValueError("Hackage source archive differs from the checked release archive")
    cabal_upload(docs, publish, True)
    # Hackage stores the uncompressed tar; served HTML receives its own CSS.
    if remote(base + "/docs.tar") != gzip.decompress(docs.read_bytes()):
        raise ValueError("Hackage documentation differs from the checked release archive")
    print(f"PASS: Hackage source and documentation at {base}")
    return served


def consumer(source: bytes, root: Path, offline: bool = False) -> None:
    version = metadata(root)
    example = root / "examples/typed-values"
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-public-consumer-") as temporary:
        directory = Path(temporary)
        (directory / "source.tar.gz").write_bytes(source)
        for name in ["Main.hs", "libtmux-typed-values.cabal", "README.md"]:
            shutil.copy2(example / name, directory / name)
        project = f"packages: . source.tar.gz\nconstraints: {PACKAGE} =={version}\ntests: False\n"
        if offline:
            index = re.search(
                r"^index-state:.*$", (root / "cabal.project").read_text(), re.MULTILINE
            )
            if index is None:
                raise ValueError("Offline release consumers need the project's index-state")
            project += index[0] + "\n"
        (directory / "cabal.project").write_text(project)
        if not offline:
            subprocess.run(["cabal", "update"], cwd=directory, check=True, timeout=QUICK)
        flags = ["--offline"] if offline else []
        subprocess.run(
            ["cabal", "build", "exe:typed-values", *flags],
            cwd=directory,
            check=True,
            timeout=BUILD,
        )
        executable = subprocess.check_output(
            ["cabal", "list-bin", "exe:typed-values", *flags],
            cwd=directory,
            text=True,
            timeout=QUICK,
        ).strip()
        result = subprocess.run(
            [executable], cwd=directory, capture_output=True, check=True, timeout=QUICK
        )
        if result.stdout != (example / "expected.stdout").read_bytes() or result.stderr:
            raise ValueError("Public Hackage archive consumer produced unexpected output")
    print("PASS: release archive installed and executed outside the checkout")


def publish_mode(value: str) -> bool:
    """Read ``true`` or ``false``, so a workflow can pass its input without an ``if``."""
    if value not in {"true", "false"}:
        raise argparse.ArgumentTypeError("expected true or false")
    return value == "true"


def parse(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the command line; an empty ``--tag`` means no tag."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "prepare", "verify", "upload"])
    parser.add_argument("--directory", type=Path, default=ROOT / "dist-newstyle/release")
    parser.add_argument("--tag", help="the Git tag; it must be v followed by the Cabal version")
    parser.add_argument(
        "--publish",
        nargs="?",
        const=True,
        default=False,
        type=publish_mode,
        metavar="true|false",
        help="publish a matching tag instead of a candidate; a bare flag means true",
    )
    parser.add_argument(
        "--require-token", action="store_true", help="check also needs HACKAGE_AUTH_TOKEN"
    )
    args = parser.parse_args(argv)
    args.tag = args.tag or None
    return args


def main(argv: list[str] | None = None) -> None:
    args = parse(argv)
    try:
        if args.command == "check":
            print(check(ROOT, args.publish, args.tag, args.require_token))
        elif args.command == "prepare":
            prepare(args.directory.resolve(), ROOT)
        elif args.command == "verify":
            verify(args.directory, ROOT)
            print("PASS: release archive identity and checksums")
        else:
            consumer(upload(args.directory, ROOT, args.publish, args.tag), ROOT)
    except (
        ValueError,
        OSError,
        tarfile.TarError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"Release failed: {redacted(str(error))}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
