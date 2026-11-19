# Find tmux options and hooks

Use [`serverCapabilities`](../src/LibTmux/Server.hs) to read the version
of the daemon you opened. Pass those capabilities to
[`lookupOption`](../src/LibTmux/Options.hs) or
[`lookupHook`](../src/LibTmux/Options.hs). Use the full native name, such
as `history-limit` or `after-new-session`. The
[creation example](creation.md) prints the option's value kind and the
hook's scope.

[`knownOptions`](../src/LibTmux/Options.hs) lists names, types, supported
scopes, array shape and named choices.
[`knownHooks`](../src/LibTmux/Options.hs) lists events and their scopes.
Both report when each entry became available within the pinned releases.

The catalogue selects the latest pinned table at or below the daemon's
reported release. The pins span tmux 3.3a through 3.8. Entries already
available at 3.3a report that release as their first qualified version.
A newer daemon can have additional entries. See the
[tmux source pins and table digests](../scripts/generate_options/sources.json).
