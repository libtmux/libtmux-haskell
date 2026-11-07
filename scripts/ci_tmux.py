"""Build-cache support for the exact tmux releases exercised by CI."""

import hashlib
import json
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / ".github/tmux-releases.json").read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cache_key(identity):
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return f"haskell-tmux-v1-{identity['version']}-{fingerprint}"


def valid(prefix, identity):
    for parent in prefix.parents:
        if parent.is_symlink():
            raise ValueError("Refusing a symlinked cache ancestor")
    binary = prefix / "bin/tmux"
    try:
        if any(path.is_symlink() for path in [prefix, binary.parent, binary]):
            return False
        record = json.loads((prefix / "build.json").read_text())
        if record != {"identity": identity, "sha256": digest(binary)}:
            return False
        reported = subprocess.check_output([binary, "-V"], text=True, timeout=1).strip()
        return reported == "tmux " + identity["version"]
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def prepare(prefix, identity, build):
    if valid(prefix, identity):
        return False
    if prefix.is_symlink():
        prefix.unlink()
    elif prefix.exists():
        shutil.rmtree(prefix)
    build(prefix, identity)
    binary = prefix / "bin/tmux"
    reported = subprocess.check_output([binary, "-V"], text=True, timeout=1).strip()
    if reported != "tmux " + identity["version"]:
        raise ValueError(f"Built executable reports {reported!r}")
    (prefix / "build.json").write_text(json.dumps({"identity": identity, "sha256": digest(binary)}, indent=2) + "\n")
    return True


def output(command):
    return subprocess.check_output(command, text=True).strip()


def identify(version):
    if version not in PINS:
        raise ValueError(f"Unpinned tmux release: {version}")
    image = [os.environ.get(key, "") for key in ["ImageOS", "ImageVersion"]]
    if not all(image):
        raise ValueError("Runner ImageOS and ImageVersion are required")
    return {"version": version, "source": PINS[version],
            "image": "-".join(image), "arch": platform.machine(),
            "recipe": digest(Path(__file__)),
            "compiler": output(["cc", "--version"]),
            "packages": output(["dpkg-query", "-W", "-f=${Package}=${Version}\n",
                "gcc", "libc6", "libevent-dev", "libncurses-dev", "make", "pkg-config", "bison"]),
            "configure": ["--disable-utf8proc"], "CFLAGS": "-O2"}


def build(prefix, identity):
    prefix.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="source-", dir=prefix.parent) as directory:
        directory = Path(directory)
        archive = directory / "tmux.tar.gz"
        version = identity["version"]
        url = f"https://github.com/tmux/tmux/releases/download/{version}/tmux-{version}.tar.gz"
        with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as target:
            shutil.copyfileobj(response, target)
        if digest(archive) != identity["source"]:
            raise ValueError("Official release archive failed SHA-256 verification")
        with tarfile.open(archive) as source:
            source.extractall(directory, filter="data")
        source = directory / ("tmux-" + version)
        env = dict(os.environ, CC="cc", CFLAGS=identity["CFLAGS"], CPPFLAGS="", LDFLAGS="", MAKEFLAGS="")
        for command in [["./configure", "--prefix=" + str(prefix), *identity["configure"]],
                        ["make", "-j2"], ["make", "install"]]:
            subprocess.run(command, cwd=source, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["matrix", "plan", "prepare"])
    parser.add_argument("version", choices=sorted(PINS), nargs="?")
    args = parser.parse_args()
    if args.operation == "matrix":
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write("tmux=" + json.dumps(list(PINS)) + "\n")
        return
    if args.version is None:
        parser.error("plan and prepare require an exact release")
    identity = identify(args.version)
    prefix = ROOT / ".cache/ci-tmux" / args.version
    if args.operation == "prepare":
        rebuilt = prepare(prefix, identity, build)
        print(f"tmux {args.version}: {'rebuilt' if rebuilt else 'validated cache'}")
        if rebuilt and os.environ.get("CACHE_HIT") == "true":
            print("::warning::An invalid immutable cache was rebuilt; bump the recipe to replace its key.")
    else:
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"key={cache_key(identity)}\nprefix={prefix}\nbinary={prefix / 'bin/tmux'}\n")


if __name__ == "__main__":
    main()
