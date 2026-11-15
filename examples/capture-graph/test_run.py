"""Failure and cancellation checks for the owned example fixture."""

import gc
import os
import select
import shutil
import signal
import subprocess
import threading
import warnings
from collections.abc import Callable
from contextlib import ExitStack

import pytest
from run import exited, fixture


@pytest.fixture
def tmux_binary() -> str:
    selected = os.environ.get("LIBTMUX_TEST_TMUX")
    assert selected, "set LIBTMUX_TEST_TMUX to a released tmux binary"
    binary = shutil.which(selected)
    assert binary is not None, "select an installed tmux release"
    return binary


@pytest.fixture
def verify_failure(tmux_binary: str) -> Callable[[str, BaseException], None]:

    def verify(stage: str, problem: BaseException) -> None:
        with ExitStack() as owners:
            observed = []

            def checkpoint(current, descriptors, _socket):
                if current == stage:
                    for descriptor in descriptors:
                        duplicate = os.dup(descriptor)
                        owners.callback(os.close, duplicate)
                        observed.append(duplicate)
                    if stage == "daemon-ready":
                        raise problem

            with (
                pytest.raises(type(problem)) as result,
                fixture(tmux_binary, checkpoint),
            ):
                raise problem
            assert result.value is problem
            assert not getattr(problem, "__notes__", []), "cleanup must be verified"
            assert len(observed) == (1 if stage == "daemon-ready" else 2)
            ready = select.poll()
            for descriptor in observed:
                ready.register(descriptor, select.POLLIN)
            assert {descriptor for descriptor, _ in ready.poll(0)} == set(observed)

    return verify


def test_setup_failure_reaps_the_daemon_before_session_dispatch(
    verify_failure: Callable[[str, BaseException], None],
) -> None:
    verify_failure("daemon-ready", RuntimeError("setup stopped"))


def test_callback_failure_observes_daemon_and_pane_exit(
    verify_failure: Callable[[str, BaseException], None],
) -> None:
    verify_failure("pane-ready", RuntimeError("callback failed"))


def test_callback_cancellation_observes_daemon_and_pane_exit(
    verify_failure: Callable[[str, BaseException], None],
) -> None:
    verify_failure("pane-ready", KeyboardInterrupt())


@pytest.mark.parametrize("problem_type", [None, RuntimeError, KeyboardInterrupt])
def test_additional_panes_are_owned_on_success_failure_and_cancellation(
    tmux_binary: str,
    monkeypatch: pytest.MonkeyPatch,
    problem_type: type[BaseException] | None,
) -> None:
    problem = problem_type("created callback failed") if problem_type else None
    with ExitStack() as owners:
        observed = []

        def observe(descriptors):
            observed.append(len(descriptors))
            assert len(descriptors) == 3, "daemon and both pane processes must be owned"
            exited(descriptors)

        def body():
            with fixture(tmux_binary) as (socket, environment):
                created = subprocess.run(
                    [
                        tmux_binary,
                        "-N",
                        "-S",
                        socket,
                        "new-session",
                        "-d",
                        "-s",
                        "extra",
                        "-P",
                        "-F",
                        "#{pane_pid}",
                        "/bin/cat",
                        "-",
                    ],
                    env=environment,
                    capture_output=True,
                    check=True,
                    timeout=1,
                )
                descriptor = os.pidfd_open(int(created.stdout))
                owners.callback(os.close, descriptor)
                if problem is not None:
                    raise problem
                return descriptor

        with monkeypatch.context() as patched:
            patched.setattr("run.exited", observe)
            if problem is None:
                descriptor = body()
                ready = select.poll()
                ready.register(descriptor, select.POLLIN)
                assert len(ready.poll(0)) == 1
            else:
                with pytest.raises(type(problem)) as result:
                    body()
                assert result.value is problem
                assert not getattr(problem, "__notes__", []), "cleanup must be verified"
        assert observed == [3]


def test_creation_cancellation_reports_the_untracked_pane(tmux_binary: str) -> None:
    with ExitStack() as owners, warnings.catch_warnings(record=True) as emitted:
        warnings.simplefilter("always", ResourceWarning)
        observed = []
        stages = []
        problems = []
        monitor = None

        def checkpoint(stage, descriptors, socket=None):
            nonlocal monitor
            stages.append(stage)
            if stage != "daemon-ready":
                return
            assert socket is not None, "startup must expose its owned endpoint"
            daemon = os.dup(descriptors[0])
            owners.callback(os.close, daemon)
            observed.append(daemon)
            environment = {
                key: value
                for key, value in os.environ.items()
                if key not in {"TMUX", "TMUX_PANE"}
            }

            def command(*arguments):
                return subprocess.run(
                    [tmux_binary, "-u", "-N", "-S", socket, *arguments],
                    env=environment,
                    capture_output=True,
                    check=True,
                    timeout=1,
                )

            command(
                "set-hook",
                "-g",
                "after-new-session",
                "wait-for -S example-created ; wait-for example-held",
            )

            def interrupt_creation():
                try:
                    command("wait-for", "example-created")
                    receipt = command("list-panes", "-a", "-F", "#{pane_pid}")
                    values = receipt.stdout.decode("ascii").split()
                    assert len(values) == 1
                    pane = os.pidfd_open(int(values[0]))
                    owners.callback(os.close, pane)
                    observed.append(pane)
                except BaseException as problem:  # noqa: BLE001 - report monitor failures to the owning test.
                    problems.append(problem)
                finally:
                    os.kill(os.getpid(), signal.SIGINT)

            monitor = threading.Thread(target=interrupt_creation)
            monitor.start()

        try:
            with (
                pytest.raises(KeyboardInterrupt) as result,
                fixture(tmux_binary, checkpoint),
            ):
                pytest.fail("fixture yielded while session creation was held")
        finally:
            if monitor is not None:
                monitor.join(timeout=1)
                assert not monitor.is_alive(), "creation monitor must join"
        assert problems == []
        assert stages == ["daemon-ready"]
        assert len(observed) == 2
        assert result.value.__notes__ == [
            "owned fixture cleanup: session creation failed before pane exit ownership was established"
        ]
        ready = select.poll()
        for descriptor in observed:
            ready.register(descriptor, select.POLLIN)
        assert {descriptor for descriptor, _ in ready.poll(0)} == set(observed)
        gc.collect()
        assert [
            str(warning.message)
            for warning in emitted
            if warning.category is ResourceWarning
        ] == []


def test_failed_command_retirement_does_not_enter_an_unbounded_wait(
    tmux_binary: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    primary = RuntimeError("session response failed")
    clients = []
    original = subprocess.Popen

    class FailedRead(original):
        def communicate(self, *arguments, **keywords):
            if "new-session" in self.args:
                clients.append(self)
                raise primary
            return super().communicate(*arguments, **keywords)

        def kill(self):
            if "new-session" in self.args:
                raise OSError("command retirement failed")
            return super().kill()

        def wait(self, timeout=None):
            if "new-session" in self.args and timeout is None:
                raise AssertionError("command cleanup entered an unbounded wait")
            return super().wait(timeout=timeout)

    with monkeypatch.context() as patched:
        patched.setattr("run.subprocess.Popen", FailedRead)
        try:
            with pytest.raises(RuntimeError) as result, fixture(tmux_binary):
                pytest.fail("fixture yielded after failed session response")
        finally:
            reaped = [client.returncode is not None for client in clients]
            for client in clients:
                if client.poll() is None:
                    original.kill(client)
                original.wait(client, timeout=1)
        assert result.value is primary
        assert reaped == [True], "fixture must join its command child"
        assert "session command cleanup: command retirement failed" in primary.__notes__
