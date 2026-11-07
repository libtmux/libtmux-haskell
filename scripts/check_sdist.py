"""Build and execute a public consumer from the core source archive."""

from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "libtmux-haskell.cabal"


def run(args, cwd):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    version = re.search(r"^version:\s*(\S+)", MANIFEST.read_text(), re.MULTILINE).group(1)
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-consumer-") as directory:
        directory = Path(directory)
        archives = directory / "archives"
        run(["cabal", "sdist", "all", "--output-directory=" + str(archives)], ROOT)
        archive = archives / f"libtmux-haskell-{version}.tar.gz"
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                name = Path(member.name)
                if name.is_absolute() or ".." in name.parts:
                    raise ValueError("Unsafe source archive member")
                if member.isfile():
                    local = ROOT.joinpath(*name.parts[1:])
                    if source.extractfile(member).read() != local.read_bytes():
                        raise ValueError(f"Archive member differs from source: {local.name}")
        consumer = directory / "consumer"
        consumer.mkdir()
        (consumer / "cabal.project").write_text(
            "packages: . ../archives/*.tar.gz\nindex-state: 2026-11-06T00:00:00Z\ntests: False\n")
        (consumer / "consumer.cabal").write_text(f"""cabal-version: 3.18
name: archive-consumer
version: 0.0.0
build-type: Simple
executable archive-consumer
  main-is: Main.hs
  default-language: GHC2024
  default-extensions: OverloadedStrings
  ghc-options: -Wall -Werror
  build-depends: base >=4.22 && <4.23, libtmux-haskell =={version}
""")
        (consumer / "Main.hs").write_text("""module Main (main) where
import LibTmux.Id (parseWindowId, renderWindowId)
import LibTmux.Value (mkDimension, dimensionValue)
import LibTmux.Version (parseVersion, renderVersion, requireSupported)
main :: IO ()
main = do
  version <- either (fail . show) pure (parseVersion "tmux 3.3\\n" >>= requireSupported)
  window <- either (fail . show) pure (parseWindowId "@17")
  width <- either (fail . show) pure (mkDimension 120)
  print (renderVersion version, renderWindowId window, dimensionValue width)
""")
        run(["cabal", "build", "exe:archive-consumer", "--offline"], consumer)
        executable = subprocess.check_output(
            ["cabal", "list-bin", "exe:archive-consumer", "--offline"], cwd=consumer, text=True).strip()
        result = subprocess.run([executable], cwd=directory, check=True, capture_output=True, text=True)
        if result.stdout != '("3.3","@17",120)\n' or result.stderr:
            raise ValueError("Archive consumer produced unexpected output")
        print("PASS: archive members and isolated public consumer")


if __name__ == "__main__":
    main()
