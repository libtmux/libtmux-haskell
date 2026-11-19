# Check old-daemon refusal

CI runs this outer check on released tmux 3.2a and 3.3, and on 3.0a and
3.1c through a 3.3a client. It starts a private daemon, installs adversarial
hooks and checks the public Server refusal before comparing daemon state.

The runner is a dedicated Linux child subreaper because 3.0a and 3.1c have
no foreground daemon mode. It holds every adopted child through a pidfd,
signals only those owners and verifies their exit before removing its directory.
An empty child snapshot does not complete cleanup: the final kernel wait must
report no children. Command output uses files because old daemons retain stdout
pipes, and each captured stream is limited to 64 KiB.

Build `test:floor` first. Run `uv run scripts/check_floor/check_floor.py`
with a released `--daemon`, a compatible `--client` and the daemon release
as `--expect`. Use `--consumer` to select a separately built executable.
