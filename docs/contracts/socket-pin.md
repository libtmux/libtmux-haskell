# Private socket ownership

The private pin component admits one filesystem socket and keeps a hard link
to its inode. Replacing the public pathname does not change that link. This
component is an implementation prerequisite; it is not a public `Client`,
process transport, bootstrap protocol or runtime lease manager.

## Admission

The initial profile is Linux x86_64 with filesystem Unix sockets and Linux
POSIX permission/ACL semantics. It requires canonical absolute byte paths:
no embedded NUL, empty component, dot, dot-dot or symlink component. The
socket and supplied pin parent are separate inputs. The parent remains
caller-owned; the library creates a fresh child beneath it.

Directory traversal uses no-follow directory descriptors from `/`. Each
directory must belong to the effective UID or root. A group/other-writable
directory must be sticky; the next child must also have a trusted owner.
With Linux POSIX ACLs, group mode bits represent the ACL mask. This policy
therefore rejects effective ACL-granted write on non-sticky ancestors.
Read-only directory opens also require read access; execute-only ancestors
are outside this initial profile.

The socket must belong to the captured effective UID and have owner-write
permission. Its mode need not be 0600: tmux uses group-write and attachment
execute bits. Kernel permission and filesystem errors remain available as
the cause of `SocketPinUnavailable`; metadata checks do not prove connection
permission or daemon liveness.

The component creates a random private directory, normalizes only that owned
directory to 0700, and verifies its owner, type and device/inode. The actual
alias must fit 107 bytes plus its terminating NUL. Paths remain bytes; no
UTF-8 decoding occurs in pin acquisition or cleanup.

One atomic hard-link attempt creates the alias. Admission checks its type,
owner, write permission and device/inode against the pre-link observation.
There is no overwrite, public-path fallback or retry on another filesystem.
A successful link is the adoption point. Pre/post metadata catches ordinary
replacement; it does not prove continuous identity with the first stat if
an inode was recycled before linking. No prior reference crosses that point.

After validation, nonblocking `getrandom` supplies a fresh 32-byte generation
token. Entropy failure is explicit. Device/inode, PID, timestamps and the
temporary directory suffix do not supply the token. Two acquisitions of one
socket establish separate generations.

## Ownership and cleanup

An explicit private owner exists before acquisition creates names. It
records each created directory, attempted link and confirmed alias while
asynchronous cancellation is masked. A short mutex serializes acquisition
and close. Filesystem calls occur outside STM; no finalizer or global reaper
owns cleanup.

The caller must retain the owner after any acquisition or cleanup exception.
Cancellation preserves its recorded resources and remains an asynchronous
exception. The future runtime must reserve cleanup capacity before starting
acquisition and retain the owner until all children have finished. This
component does not supply that admission/lease protocol yet.

Close checks the directory and alias identities, unlinks only its owned
alias, then removes the empty owned directory. It never recursively deletes
contents. An existing destination after a failed `EEXIST` link is not owned.
An uncertain link outcome requires matching identity before cleanup. Missing
owned names can complete cleanup steps; identity mismatch, unexpected
children and other failures leave explicit cleanup debt. Completed unlink
steps remain recorded so a later close can finish. Close is idempotent, and
a used owner cannot acquire a new generation.

Credentials and the filesystem namespace must remain stable. Root and
deliberate same-UID interference are outside this profile. A trusted process
can invalidate the environment by changing permissions, renaming ancestors
or changing mounts. Masking unsafe filesystem calls does not provide a hard
deadline on a stalled filesystem.

## Evidence boundary

The private integration cases exercise public pathname replacement, distinct
generation tokens, wrong types, symlinks, owner-write checks, unsafe ancestors,
invalid paths, raw-byte filesystem names, the alias length boundary, caller
cancellation, retained cleanup debt, replacement directories and cross-device
failure. Exact releases and source identities belong to recorded runs.
Private checkpoints exercise cancellation after resource registration and
before publication, injected failures before stat/entropy reads, source
replacement before linking, and `EEXIST` without claiming the existing alias.
Three deliberately broken source copies demonstrate that missing directory
registration, claiming an existing matching inode, and catching cancellation
as an ordinary error fail their intended assertions.

The raw-byte filesystem case does not qualify subprocess argv encoding.
The current `typed-process`/`process` boundary lost a non-UTF-8 argument byte
in a separate attempted invocation; byte-preserving child launch remains an
open transport requirement. No process-global encoding change is authorized
as a substitute.

Other-owner and ACL fixtures, actual stat/entropy syscall failures, unsupported
hard-link filesystems, child-lease races, daemon retirement, no-start dispatch
and first-session bootstrap still need their own evidence. Checkpoints do not
prove arbitrary interruption inside an OS call. Successful pin acquisition
alone does not pass those gates or the transport task.
