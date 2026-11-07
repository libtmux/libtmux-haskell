# Client interaction and waiting jobs

Proposed operation contracts; no wrapper or completion protocol is qualified.
The source comparison covers tmux 3.3 and 3.8. Intermediate capability
boundaries still require inspection and real-tmux tests.

## Targets and results

A `ClientSelector` names the current occupant of a client name or tty. It is
not an enduring process identity. Every client-directed operation requires
that selector; format context uses a separate pane, session or window-link
target. No omitted target selects a recently active client.

`RequestProcessed` means tmux accepted and processed the request. It does
not establish that an overlay appeared, a terminal redrew or a client became
locked. Several handlers successfully skip an ineligible client or an
already occupied prompt/overlay. Observational checks are separate results.

| Operations | Native modes | Completion |
| --- | --- | --- |
| Refresh client | Display refresh or parameterless clipboard request | Request processed; clipboard response is asynchronous. |
| Suspend client | Explicit client selector | Suspend message requested; no OS stopped/resumed assertion. |
| Lock client/session/server | Single selector, exact session, or explicit whole server | Configured lock command requested; skipped clients and program lifetime prevent an “all secured” result. |
| Detach client | Detach or replace that client with an explicit shell payload | Detach/replacement requested; replacement process completion is outside this command. |
| Detach cohort | All except one explicit selector, or a captured cohort with observation time | Ordered per-client outcomes; fanout is non-atomic. `-a` means all-except, not all clients. |
| Switch client | Explicit client, exact destination session, environment-update policy | Request processed; attachment readback is an observation. |

Clipboard request `refresh-client -l` already exists in 3.3. Its optional
pane argument in that release is absent in 3.8, so the common operation
uses the parameterless form. A Python minimum-version guard does not
override this command source evidence.

## Prompts and overlays

| Operation | Inputs | Result boundary |
| --- | --- | --- |
| Confirm | Client, tmux action, prompt format, supported confirmation key/default, submit or await-request mode | Submission or request termination; neither exit zero nor exit one alone identifies the answer or downstream action result. |
| Command prompt | Client, substitution template, prompt/input lists, one input mode, completion type, submit or await mode | Submission or request termination. Text is substituted into actions; it is not returned as input text. Incremental mode may run actions repeatedly. |
| Menu | Client and format context, typed entries, keys/actions, geometry and styles | Request termination when the menu is freed. The selected action runs on another queue; no selected-item or action-completion result is inferred. |
| Popup | Client and format context; open or clear-overlay intent; explicit shell/native-argv process mode, geometry, cwd, environment, close policy | Preserve tmux termination information. UI closure, signal, process exit and an existing overlay do not share a universal process-exit meaning. |

Prompt, shell, tmux command and literal text are distinct inputs. Qualify
comma serialization, substitutions and format escaping. Reject conflicting
modes and unsupported flags before dispatch. Popup dimensions distinguish
cells from percentages; positions distinguish coordinates, supported anchors
and explicit formats. Endpoint cwd values do not undergo implicit local
`expanduser` processing.

Cancellation may leave the request, popup process or selected action alive.
There is no stable owned overlay ID. A timeout must not clear a replacement
overlay merely because it occupies the same client.

## Display and attachment

Display-message acquisition becomes `evaluateFormat` with explicit context
and bounded bytes using the single-evaluation envelope in the
[framing contract](framing.md). A final LF alone cannot separate after-hook
output from the scalar. Literal messages,
format messages, format listings and verbose traces are separate modes;
diagnostic listings are not a lossless `key=value` map. A destination client
does not necessarily become tmux's chosen format client. Reject a stronger
context guarantee until its receipt is proved.

Pane-number display has two different native operations. tmux 3.3 targets a
client overlay and can wait for selection or expiry. tmux 3.8 targets a pane
mode and returns after installation. A shared `-t` argument would target
different objects. Gate `showPaneNumbersOnClient` and `enterPaneNumbersMode`
separately; identify their exact supported release intervals before dispatch.

Attachment owns an interactive tmux client through the pinned socket. The
caller supplies terminal IO, an exact session and explicit attachment and
environment policies. Preserve terminal setup/restoration and return an
attachment exit report, or a scoped handle with separately proved readiness.
A pipe-only command runner is insufficient. Detaching other clients and
signaling their parents require explicit modes.

## Waiting operations

| Operation | Modes | Completion and remaining responsibility |
| --- | --- | --- |
| Run shell | Shell payload or tmux actions; await or submit; checked delay; exact context and explicit output sink | Awaited command termination or submission evidence. Cancellation need not stop the server job. Modern extra arguments bind tmux formats; they are not executable argv. |
| If shell | Exact context, shell condition, then/optional-else actions, await or submit | A false/signaled condition selects else. Success does not identify the branch or prove background actions finished. |
| Wait channel | Await signal, signal, acquire lock or release lock | Await/acquire use waiting admission. A signal may precede its waiter. Locks are server state, not process-owned leases; client exit does not release them. |

Baseline run-shell uses an explicit pane output sink and returns completion
evidence, without promising stdout bytes. tmux 3.3 sends output to pane view
mode, while 3.8 can return output to a waiting command client. Captured-output
mode needs its own capability and framing proof. Output-to-pane is a visible
pane-mode change.

Human interaction and waiting jobs use their reserved admission class.
Inspection and signaling must progress when waiting slots are full. Keep
uncertain server-job or lock-acquisition debt until completion is established
or responsibility is explicitly detached. Do not retry automatically,
unconditionally unlock after canceled acquisition, or free capacity merely
because a waiting caller exited.

## Qualification cases

Cover absent/reused clients, terminal versus control clients, occupied UI,
small geometry, declined confirmation versus action failure, popup nonzero
and signal outcomes, detach-all-except target disappearance, both pane-number
semantics, run-shell output routing, false if-shell without else,
signal-before-wait, canceled lock acquisition, terminal restoration and
inspection under full waiting admission. Own every PTY, client and daemon.

Source entry points: [client targeting](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-find.c),
[baseline UI](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-display-menu.c),
[baseline pane numbers](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-display-panes.c),
[3.8 pane mode](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-choose-tree.c),
[baseline run-shell](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-run-shell.c),
and [wait-channel state](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-wait-for.c).
