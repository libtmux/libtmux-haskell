# tmuxp workspace fixtures

The 23 YAML files and the MIT license are byte-identical to
[tmuxp v1.74.0](https://github.com/tmux-python/tmuxp/tree/91ac8519ac7d54bf540e3488637b9d26a1ee80ef/examples).
The JSON files come from the
[pinned Rust fixtures](https://github.com/libtmux/libtmux-rs/tree/bc64de8032e48ca3144f85b5db953a3a41394ae0/crates/tmux-workspace/tests/fixtures/tmuxp/expected).
Their generator calls tmuxp's loader and projects the inherited pane settings.
We reran it against all 23 YAML files using tmuxp 1.74.0, libtmux 0.61.0
and PyYAML 6.0.3. See the source generator for the expansion inputs.
