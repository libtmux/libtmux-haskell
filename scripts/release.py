"""Prepare, verify and upload the core package and Haddock documentation."""

import argparse
import gzip
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "libtmux-haskell"


def metadata(root, tag=None):
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


def verify(directory, root):
    version = metadata(root)
    identifier = f"{PACKAGE}-{version}"
    source = directory / f"{identifier}.tar.gz"
    docs = directory / f"{identifier}-docs.tar.gz"
    if not source.is_file() or not docs.is_file():
        raise ValueError("Both source and documentation release archives are required")
    expected = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                       for path in [source, docs])
    if not (directory / "SHA256SUMS").is_file() or (directory / "SHA256SUMS").read_text() != expected:
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


def prepare(directory, root):
    version = metadata(root)
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cabal", "sdist", f"pkg:{PACKAGE}", f"--output-directory={directory}"], cwd=root, check=True)
    subprocess.run(["cabal", "haddock", f"lib:{PACKAGE}", "--haddock-for-hackage", "--offline"],
                   cwd=root, check=True)
    docs = root / "dist-newstyle" / f"{PACKAGE}-{version}-docs.tar.gz"
    shutil.copy2(docs, directory / docs.name)
    source = directory / f"{PACKAGE}-{version}.tar.gz"
    (directory / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in [source, directory / docs.name]
    ))
    verify(directory, root)
    consumer(source.read_bytes(), root, offline=True)
    print("PASS: source and Haddock release archives")


def remote(url):
    request = Request(url + "?release_check=" + uuid.uuid4().hex,
                      headers={"User-Agent": "libtmux-haskell-release", "Cache-Control": "no-cache"})
    try:
        with urlopen(request, timeout=30) as response:
            return response.read()
    except HTTPError as error:
        if error.code == 404:
            return None
        raise ValueError(f"Hackage verification returned HTTP {error.code}") from error


def cabal_upload(path, publish, documentation):
    token = os.environ["HACKAGE_AUTH_TOKEN"]
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-upload-") as temporary:
        config = Path(temporary) / "config"
        config.write_text("repository hackage.haskell.org\n  url: https://hackage.haskell.org/\n  secure: True\n")
        command = ["cabal", f"--config-file={config}", "upload", f"--token={token}"]
        if publish:
            command.append("--publish")
        if documentation:
            command.append("--documentation")
        command.append(str(path))
        result = subprocess.run(command, capture_output=True, text=True)
    output = (result.stdout + result.stderr).replace(token, "[redacted]")
    if result.returncode:
        raise ValueError(f"Hackage upload failed (exit {result.returncode}): {output}")
    print(output, end="")


def upload(directory, root, publish=False, tag=None):
    if publish and tag is None:
        raise ValueError("Publishing requires a matching version tag")
    version = metadata(root, tag)
    source, docs = verify(directory, root)
    if not os.environ.get("HACKAGE_AUTH_TOKEN"):
        raise ValueError("Set HACKAGE_AUTH_TOKEN in the hackage environment; see .github/RELEASE.md")
    base = f"https://hackage.haskell.org/package/{PACKAGE}-{version}"
    if not publish:
        base += "/candidate"
    url = f"{base}/{source.name}"
    existing = remote(url)
    if publish and existing is not None and existing != source.read_bytes():
        raise ValueError("Hackage already serves different source bytes; do not overwrite this version")
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


def consumer(source, root, offline=False):
    version = metadata(root)
    example = root / "examples/typed-values"
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-public-consumer-") as temporary:
        directory = Path(temporary)
        (directory / "source.tar.gz").write_bytes(source)
        for name in ["Main.hs", "libtmux-typed-values.cabal", "README.md"]:
            shutil.copy2(example / name, directory / name)
        project = f"packages: . source.tar.gz\nconstraints: {PACKAGE} =={version}\ntests: False\n"
        if offline:
            index = re.search(r"^index-state:.*$", (root / "cabal.project").read_text(), re.MULTILINE)
            if index is None:
                raise ValueError("Offline release consumers need the project's index-state")
            project += index[0] + "\n"
        (directory / "cabal.project").write_text(project)
        if not offline:
            subprocess.run(["cabal", "update"], cwd=directory, check=True)
        flags = ["--offline"] if offline else []
        subprocess.run(["cabal", "build", "exe:typed-values", *flags], cwd=directory, check=True)
        executable = subprocess.check_output(
            ["cabal", "list-bin", "exe:typed-values", *flags], cwd=directory, text=True).strip()
        result = subprocess.run([executable], cwd=directory, capture_output=True, check=True)
        if result.stdout != (example / "expected.stdout").read_bytes() or result.stderr:
            raise ValueError("Public Hackage archive consumer produced unexpected output")
    print("PASS: release archive installed and executed outside the checkout")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "prepare", "verify", "upload"])
    parser.add_argument("--directory", type=Path, default=ROOT / "dist-newstyle/release")
    parser.add_argument("--tag")
    parser.add_argument("--publish", action="store_true", help="publish a matching tag instead of a candidate")
    args = parser.parse_args()
    try:
        if args.command == "check":
            print(metadata(ROOT, args.tag))
        elif args.command == "prepare":
            prepare(args.directory.resolve(), ROOT)
        elif args.command == "verify":
            verify(args.directory, ROOT)
            print("PASS: release archive identity and checksums")
        else:
            consumer(upload(args.directory, ROOT, args.publish, args.tag), ROOT)
    except (ValueError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release failed: {error}\n")


if __name__ == "__main__":
    main()
