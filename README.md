![libtmux for Haskell](docs/assets/logo-128.png)

# libtmux for Haskell

libtmux for Haskell provides distinct tmux entity IDs, checked dimensions
and indices, and stable-release parsing. These values are pure; constructing
or reading them starts no tmux process. The client and observation APIs are
under development.

Use GHC 9.14.1 with GHC2024 and Cabal 3.18.2.0 on Linux x86_64.
[Add the pinned source dependency](docs/installation.md) to a Cabal application,
or run the complete example from this checkout:

```console
$ cabal run --verbose=0 typed-values
```

<!-- example: typed-values -->
```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Construct tmux domain values without starting a process or contacting a server.
module Main (main) where

import LibTmux.Id (parseWindowId, renderWindowId)
import LibTmux.Value (dimensionValue, mkDimension)
import LibTmux.Version (parseVersion, renderVersion, requireSupported)

main :: IO ()
main = do
  version <- either (fail . show) pure $
    parseVersion "tmux 3.3\n" >>= requireSupported
  window <- either (fail . show) pure (parseWindowId "@17")
  width <- either (fail . show) pure (mkDimension 120)
  print (renderVersion version, renderWindowId window, dimensionValue width)
```

Program output:

<!-- example-output: typed-values -->
```text
("3.3","@17",120)
```

The example parses supplied values. It does not inspect an installed tmux
binary or verify that window `@17` exists. Its [source](examples/typed-values/Main.hs)
and output are checked in an isolated consumer built from the source archive.

| Task | Start here |
| --- | --- |
| Install in an application | [Cabal source dependency](docs/installation.md) |
| Understand IDs, indices and validation errors | [Typed values](docs/values.md) |
| Browse declarations and module documentation | [API guide](docs/api.md) |
| Evaluate the implemented scope and compatibility evidence | [Status](docs/status.md) |

The public package cannot yet observe or mutate a server. Complete captures,
typed queries, event streams, workspace tooling and MCP remain implementation
work; the [manual](docs/README.md) separates that work from available exports.

[Contributing](.github/CONTRIBUTING.md) · [License](LICENSE)

[Branding assets](docs/branding.md) include the logo, icons, and social cards.
