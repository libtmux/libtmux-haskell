# Run a terminal application

[`runProgram`](../src/LibTmux/Server.hs) returns an exact leader outcome and a
bounded rendered screen after cleaning up its owned session. The selected
daemon stays borrowed. Existing sessions, panes and buffers survive.

[`withProgram`](../src/LibTmux/Server.hs) supplies an interactive
[`Program`](../src/LibTmux/Program.hs) inside a scope. Send bytes, observe output
and wait for exit while the callback runs. A detached `ProgramResult` remains
usable after the scopes close; the interactive handle does not.

The [complete example](../examples/managed-program/Main.hs) runs a command,
cancels an observation, sends literal input, waits again and exercises an owning
deadline. Use the README's private demonstration server before running it.

<!-- example: managed-program -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (unless)
import Data.ByteString.Char8 qualified as Bytes
import LibTmux qualified as Tmux
import LibTmux.Capabilities qualified as Cap
import LibTmux.Program qualified as Program
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path
import System.OsString.Posix qualified as Os

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
    Tmux.withServer config $ \server -> do
      unless (Cap.supports (Tmux.serverCapabilities server) Cap.ManagedPrograms)
        (die "This example requires connected tmux 3.8 or newer")
      before <- Tmux.capture server
      result <- Tmux.runProgram server (settings "/bin/sh"
        ["-c", "printf '%s' \"$1\"; exit 7", "app", "literal ; $HOME"])
      require (result.programExit == Program.ProgramExited 7) "exit status changed"
      require ("literal ; $HOME" `Bytes.isPrefixOf` result.programOutput.screenBytes) "argv changed"
      putStrLn ("exit: " <> show result.programExit)
      putStrLn "literal argv: True"

      Tmux.withProgram server (settings "/bin/sh"
        ["-c", "IFS= read -r line; printf 'received:%s' \"$line\""]) $ \program -> do
          observing <- newEmptyMVar
          withAsync (try @AsyncException (putMVar observing () >> Program.waitProgram program)) $ \observer -> do
            takeMVar observing
            throwTo (asyncThreadId observer) ThreadKilled
            cancelled <- wait observer
            require (cancelled == Left ThreadKilled) "observation did not report cancellation"
          Program.sendProgramInput program "literal ; $HOME\n"
          Program.waitProgram program >>= \status -> require (status == Program.ProgramExited 0) "interactive exit changed"
          output <- Program.readProgramScreen program
          require ("received:literal ; $HOME" `Bytes.isInfixOf` output.screenBytes) "input changed"
      putStrLn "cancelled observation: True"
      putStrLn "interactive retry: True"

      entered <- newEmptyMVar
      expired <- try @Program.ProgramError (Tmux.withProgram server
        (settings "/bin/sh" ["-c", "trap '' HUP TERM; exec /bin/cat -"])
          {Program.executionTimeout = Just 0.5} $ \program ->
            putMVar entered () >> Program.waitProgram program)
      started <- tryTakeMVar entered
      require (started == Just () && expired == Left Program.ProgramTimedOut) "owning deadline did not clean up active work"
      putStrLn "owning deadline: True"
      after <- Tmux.capture server
      require (map (.ref) (Tmux.sessions before) == map (.ref) (Tmux.sessions after)
        && map (.ref) (Tmux.panes before) == map (.ref) (Tmux.panes after)) "borrowed resources changed"
      putStrLn "borrowed resources preserved: True"
  _ -> die "Usage: managed-program SOCKET TMUX_EXECUTABLE"

settings :: String -> [String] -> Program.ProgramOptions
settings file args = Program.programOptions (Os.fromBytestring (Bytes.pack file))
  (map (Os.fromBytestring . Bytes.pack) args)

require :: Bool -> String -> IO ()
require condition message = unless condition (die message)
```

<!-- example-output: managed-program -->
```text
exit: ProgramExited 7
literal argv: True
cancelled observation: True
interactive retry: True
owning deadline: True
borrowed resources preserved: True
```

## Check the connected daemon

`serverCapabilities` is a pure report from the daemon release accepted through
the Server's pinned socket. The client executable's release does not enable an
older daemon. `supports` and `requireCapability` use the same
[`capabilityRegistry`](../src/LibTmux/Capabilities.hs) as each operation.
[`capabilities.json`](../capabilities.json) is checked against that table.

The complete Program operations require released tmux 3.8. Older versions,
`next-3.8` and 3.8 release candidates refuse before application effects. Each
input, capture and exit operation has a separate registry entry because each
also depends on the generation witness established during startup. A dead pin
cannot route an operation to a replacement daemon.

This initial slice requires a local Linux daemon, process-group pidfd signaling
from Linux 6.9, procfs, and Bash dynamic descriptors and timed reads. Host
requirements are checked separately before creating an application. A private
bootstrap uses positional arguments, direct exec and the actual PTY. It neither
evaluates the executable and argv as shell syntax nor replaces application input
with a line-oriented protocol.

`bootstrapShell` selects Bash, defaulting to `/bin/bash`. The library probes
dynamic descriptors, a timed FIFO read, descriptor closure and `execfail` before
creating a session. Its FIFO opens read/write, so loss of the controller's
writer cannot block the open. The gate read has a separate one-second startup
lease; cleanup sends a blank claim to wake an admitted reader immediately.
`commandTimeout` bounds each native command. Neither bounds whole startup;
use `executionTimeout` for the owning setup and callback. The descriptor closes
before application exec. A delayed startup may refuse without executing the
application. Only GNU Bash 5.3.9 has been exercised
locally; these feature checks do not establish another Bash release's support.

## Configure argv and bounds

Import `LibTmux.Program` qualified for `ProgramOptions` record updates. Start
with `programOptions executable arguments`; an empty tail supports a
zero-argument executable. POSIX paths, argv and environment values retain
non-NUL bytes. A missing cwd and a failed exec have separate `ProgramStartFailed`
phases; normal application exit 127 is still `ProgramExited 127`.

| Option | Contract |
| --- | --- |
| `workingDirectory` | Strict cwd, defaulting to the caller's current directory. |
| `environment` | Overrides the daemon's inherited application environment; the ownership token is reserved. |
| `bootstrapShell` | Absolute path to Bash; unavailable or incompatible binaries refuse before application creation. |
| `columns`, `rows` | Initial geometry, at most 500 by 200 cells. Capture refuses if an external resize changes it. |
| `historyLines` | At most 10000 lines and one million cells with the screen. |
| `outputLimit` | Rendered bytes returned, from one byte to 1 MiB. |
| `commandTimeout` | Positive per-command deadline, at most ten seconds. |
| `executionTimeout` | Optional owning setup/callback deadline with a separate cleanup budget. |

The combined argv, environment and cwd limit is 8192 bytes, with at most 4096
argv entries and 4096 environment entries. Invalid inputs refuse before
application creation. Options have no `Show` instance because they may contain
credentials.

Environment names are ASCII shell identifiers. `_`, `SHLVL`, `POSIXLY_CORRECT`,
`BASH_COMPAT`, `LIBTMUX_PROGRAM_TOKEN` and the `__libtmux_` prefix are reserved.
Readonly or otherwise unassignable Bash names refuse during the preflight.
Assignments apply after the ownership claim and strict cwd change, so tmux's
client-PATH substitution and bootstrap variables cannot alter the requested
application values.

## Observe and send input

| Operation | Meaning |
| --- | --- |
| `sendProgramInput` | At most 1024 literal bytes per call, including NUL. Terminal line discipline and echo still apply. Acceptance does not prove consumption. |
| `readProgramScreen` | A bounded rendered snapshot with retained history, `omittedBytes` for this snapshot and `historyTruncated` when earlier history may be lost. |
| `waitProgram` | The real leader exit or signal after tmux's final PTY drain. Signal text preserves tmux's name or decimal spelling. |
| `waitProgramFor` | Bounds observation and returns `Nothing` without stopping the program. |
| `terminateProgram` | TERM, up to 100ms for leader exit, then group KILL and the leader outcome. |

Window removal or adding another pane invalidates exit observation. A resize
of the single owned pane keeps its exit wait valid; capture still requires the
configured geometry. At most five native observers are registered at a time,
with their client and retained-byte costs charged to the existing Runtime.

Input and capture transfer a pending pane-generation witness in the same native
queue as the operation. An external respawn refuses the stale operation. An
uncertain submitted input is never replayed. Capture uses an owned named buffer
and bounded local spool; tmux hook stdout cannot become application output.
The native capture guard requires the configured geometry before allocating
its buffer. An external resize raises a mutation refusal; owning cleanup still
works. The selected history and screen cover at most one million cells, with
at most 32 bytes per cell in released tmux 3.8. Returned bytes have the separate
`outputLimit` bound. stdout and stderr share the PTY. Capture may clip bytes
inside a UTF-8 sequence; the result is a `ByteString` with an exact omission
count.

## Cancel and recover

Cancelling a wait leaves its owner running. Cancelling the owning scope or
setting `executionTimeout` initiates cleanup before returning. Async exceptions
keep their original class. Cleanup sends signals only through the retained
identity-bound pidfd; it never reacquires a numeric PGID.

Completed cleanup proves leader exit and an empty retained process group.
Zombies, uninterruptible members, changed tmux ownership or failed cleanup may
leave an incomplete owner. Processes that create a new group or session escape
this contract. A scope does not claim exhaustive process-tree accounting.

Catch exceptions with their `ExceptionContext` when cleanup must be retried.
`programRecoveries` retrieves `ProgramRecovery` owners;
`programCleanupFailure` retains the cleanup cause alongside the original body
exception. `inspectProgramCleanup` reads local metadata without tmux IO.
`resumeProgramCleanup` retries through the retained pin and native Runtime,
including after the borrowing Server has closed. It never relaunches an
application or replays input. External replacements remain untouched; a lost
witness may require the external owner to remove its resource before retry.

The initial precreation witness conservatively observes respawns throughout the
daemon until exact pane identity is available. An unrelated respawn during that
short interval can refuse startup. Raw byte streaming, readiness predicates,
controller-crash leases, keep/detach and MCP are not implemented.
