# Capture and navigate a tmux server

[`withServer`](../src/LibTmux/Server.hs) adopts an existing tmux endpoint.
[`capture`](../src/LibTmux/Server.hs) reads it into a detached
[`Snapshot`](../src/LibTmux/Snapshot.hs) that stays usable after the handle
closes. The [README](../README.md) shows the
[complete program](../examples/capture-graph/Main.hs).

Start the [demo server](../README.md) from the README, then run from a
checkout:

```console
$ cabal run --verbose=0 capture-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

To inspect your own server, pass its socket and tmux executable instead. The
program reads that daemon; it never creates or stops it.

The library needs:

- A trusted absolute socket path.
- A writable pin directory on the socket's filesystem. The default is the
  socket's parent.
- A Linux host; see [installation](installation.md#native-backend-host-requirements).

## Physical entities and appearances

A session links windows at numeric indices. One physical window can appear at
two indices, or in several sessions. A pane belongs to its physical window; a
pane occurrence also keeps the window-link context:

```mermaid
flowchart LR
    S["Session demo"] --> L0["WindowLink index 0"]
    S --> L4["WindowLink index 4"]
    L0 --> W["Window @0"]
    L4 --> W
    W --> P["Pane %0"]
```

- `windows` and `panes` return each physical entity once.
- `windowLinks` and `paneOccurrences` return every appearance: two each in
  this demo.
- Order: lists by numeric ID; links by session ID, then window index;
  occurrences by link, then pane index. Lookups are indexed.

References:

- A reference names a target within one Server generation. Independent Server
  scopes have distinct generations.
- A lookup returns the observation in the snapshot you pass, including a later
  capture from the same Server.
- `lookupPaneId` picks a native ID's observation in the snapshot you pass. It
  does not restore an earlier targeting guarantee.

Values:

- Record updates make local values. They do not change the snapshot's indexes,
  validate the edited graph or send a command.
- Compare sizes with `dimensionValue pane.width`; dimensions have no
  [`Num`](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Prelude.html#t:Num)
  instance.
- Paths and command names keep POSIX bytes. Window and group labels are `TmuxText`;
  converting to text is explicit and can fail.

## Read captured metadata

Record dot and the matching [query field tokens](query.md) read the same
captured values. Later state changes leave earlier snapshots unchanged.
The [offline example](fixtures.md) constructs and selects these fields.

| Observation | Fields | Native meaning |
| --- | --- | --- |
| `Session` | `group :: Maybe TmuxText` | Reported group label; `Nothing` for an ungrouped session. |
| `Window` | `layout :: Text`, `zoomed :: Bool` | Opaque unzoomed layout encoding and current zoom state. A zoomed window retains its saved unzoomed layout. |
| `WindowLink` | `flags :: Text` | `window_flags` for this session/index appearance, including tmux's doubled `#` escaping. |
| `Pane` | `cursorX`, `cursorY :: Integer` | Zero-based base-screen coordinates, independent of a mode's cursor. A pending wrap can put `cursorX` at the pane width. |
| `Pane` | `modeCount :: Integer`, `mode :: Maybe Text` | Mode-stack depth and current mode name. Zero and `Nothing` describe an ordinary pane. |
| `Client` | `width :: Integer`, `height :: Maybe Integer` | Native tty size. Width can be zero; height is absent until tmux starts the terminal. Control clients have no reported height. |

Numeric cursor, mode and client-size values retain tmux's unsigned range,
including zero. They are not positive `Dimension` values. Layout text is
release-dependent and can include pane-selection metadata; the library does
not parse it. Flags belong to a link,
so a physical window's appearances can have different selections and alerts.
Group labels preserve bytes like window names; use `labelText` when text is
required.

These meanings follow the native callbacks in
[tmux 3.3a](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/format.c) and
[tmux 3.8](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/format.c).
Live checks exercised control-client sizing and an absent height on both
releases. An installed consumer also captured an attached terminal at
89 columns and 37 rows on each release.

## Errors and recovery

- Acquisition fails in `IO` with `TmuxException`.
- Pure navigation returns `Either LookupError`. A missing or foreign reference
  is never an empty result.
- A snapshot records a monotonic capture interval. It is not a transaction over
  tmux and operating-system state.

`withServer` rethrows the callback's own exception, cancellation included.

- If bounded cleanup stays incomplete, the exception context holds a
  `CleanupRecovery`.
- After a successful callback, incomplete cleanup raises `CleanupFailed`.

Catch with:

- `tryTmux`: library failures.
- [`Control.Exception.tryWithContext`](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Control-Exception.html#v:tryWithContext):
  also application exceptions and cancellation.

Both keep the
[`ExceptionWithContext`](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Control-Exception.html#t:ExceptionWithContext)
that recovery needs. A typed `try` drops it.

Import [`LibTmux.Recovery`](../src/LibTmux/Recovery.hs) for
`cleanupRecoveries` and `captureRecoveries`. They read the correlated owners
from that context.

- Inspect it locally.
- Resume cleanup. This never sends a second capture.
- Detach the uncertainty. This stops no native resource and proves nothing
  about the daemon.

Details: [process contract](https://github.com/libtmux/libtmux-haskell/blob/master/docs/contracts/process.md).

## See also

- [Offline fixtures](fixtures.md): test graph logic without tmux.
- [Performance](performance.md): capture cost by graph size.
- [Shared Runtime](shared-runtime.md): independent handle lifetimes.
- [Status](status.md): what is implemented.
