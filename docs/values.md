# Typed tmux values

[Run the complete example](../examples/typed-values/Main.hs) from a checkout:

```console
$ cabal run --verbose=0 typed-values
```

The complete program uses only pure domain constructors before printing:

<!-- example: typed-values -->
```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Construct tmux domain values without starting a process
-- or contacting a server.
module Main (main) where

import LibTmux.Id (parseWindowId, renderWindowId)
import LibTmux.Value (dimensionValue, mkDimension)
import LibTmux.Version (parseVersion, renderVersion, requireSupported)

main :: IO ()
main = do
  version <- either (fail . show) pure $
    parseVersion "tmux 3.3a\n" >>= requireSupported
  window <- either (fail . show) pure (parseWindowId "@17")
  width <- either (fail . show) pure (mkDimension 120)
  print (renderVersion version, renderWindowId window, dimensionValue width)
```

Program output:

<!-- example-output: typed-values -->
```text
("3.3a","@17",120)
```

Its only `IO` is the final print: no tmux binary, no server.

## IDs and indices describe different things

- [`SessionId`](../src/LibTmux/Id.hs) (`$`), [`WindowId`](../src/LibTmux/Id.hs)
  (`@`) and [`PaneId`](../src/LibTmux/Id.hs) (`%`) are distinct types.
- Parsers require the prefix, canonical decimal spelling and an unsigned 32-bit
  value. Leading zeroes and whitespace fail.
- Use the rendering functions to produce target text for tmux.
- An ID carries no endpoint or server lifetime. Parsing `@17` does not prove the
  window exists.
- Generation-bound references come from a validated [snapshot](capture.md).

Indices:

- [`WindowIndex`](../src/LibTmux/Value.hs): a window link's position in its
  session.
- [`PaneIndex`](../src/LibTmux/Value.hs): a pane's position in its window.
- Neither is an entity ID. A physical window can have several links, even at
  several indices in one session.

## Validate values where they enter the program

- Constructors return `Either`: dimensions must be positive, indices
  nonnegative.
- Numeric accessors return `Integer`, so reading a value never narrows it to a
  machine-sized integer.
- [`mkDimension`](../src/LibTmux/Value.hs) checks the mathematical domain. A
  tmux command can impose a smaller range; a valid dimension does not promise
  that command's maximum.

## Release admission has a limited meaning

- [`parseVersion`](../src/LibTmux/Version.hs) accepts stable releases in the
  output format of `tmux -V`, including one final LF. Development versions and
  trailing data fail.
- [`requireSupported`](../src/LibTmux/Version.hs) admits tmux 3.3a through 3.8,
  inclusive.
- Both check the release identity you supply. They do not inspect the host or
  vouch for every feature of that release.

See [status](status.md) for what is implemented.

The [API guide](api.md) links the public modules and their error types.
