# Check the connected daemon

[`serverCapabilities`](../src/LibTmux/Server.hs) reports the release read
through the opened Server's pinned socket. Use
[`supports`](../src/LibTmux/Capabilities.hs) before starting a Program;
[`requireCapability`](../src/LibTmux/Capabilities.hs) returns the unavailable
operation and daemon release. The [Program example](programs.md) uses this
query before effects. Every operation reads its floor from the same
[`capabilityRegistry`](../src/LibTmux/Capabilities.hs).

The client executable's release never enables a feature on an older daemon.
An incompatible older wire protocol raises
[`IncompatibleTmuxClientProtocol`](../src/LibTmux/Server.hs) through
[`tryTmux`](../src/LibTmux/Server.hs). It supplies no inferred daemon release.
The [graph example](../examples/capture-graph/Main.hs) handles this refusal.

The root [manifest](../capabilities.json) uses `libtmux-capabilities/1`.
It records this port and its admission floor, and projects only shared claim
IDs defined by the pinned [capability claims contract](https://github.com/libtmux/central/blob/a774f3b3a74db3dfbe19405bde3294efba37fce7/docs/decisions/0003-capability-claims.md).
The Haskell runtime capability IDs are outside that vocabulary, so its shared
claim arrays are empty. Query the Haskell registry for those operations.

[Control notifications](control.md) use the attach flags introduced in
[tmux 3.2](https://github.com/tmux/tmux/blob/bc4681c83d612a3d9609dd609e7d89b035b25dd5/cmd-attach-session.c).
The library's daemon admission floor remains 3.3a.

The unit suite compares the generated manifest byte for byte. The integration
suite checks daemon-bound discovery and Program refusal before effects.
Old-daemon lanes independently observe the actual releases 3.0a, 3.1c, 3.2a
and 3.3, then verify refusal, untouched resources and configured hooks.
The 3.0a daemon rejects the 3.3a client's wire protocol before a version query;
the other three report their actual release before floor refusal.
