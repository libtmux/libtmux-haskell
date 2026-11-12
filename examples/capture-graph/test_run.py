"""Critical failure and cancellation checks for the owned example fixture."""

from contextlib import ExitStack
import gc
import os
import select
import signal
import shutil
import subprocess
import threading
import unittest
from unittest.mock import patch
import warnings

from run import fixture, exited


class FixtureChecks(unittest.TestCase):
    def setUp(self):
        self.binary = shutil.which(os.environ.get("LIBTMUX_TEST_TMUX", "tmux"))
        self.assertIsNotNone(self.binary, "select an installed tmux release")

    def verify_failure(self, stage, problem):
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

            with self.assertRaises(type(problem)) as result:
                with fixture(self.binary, checkpoint):
                    raise problem
            self.assertIs(result.exception, problem)
            self.assertFalse(getattr(problem, "__notes__", []), "cleanup must be verified")
            self.assertEqual(len(observed), 1 if stage == "daemon-ready" else 2)
            ready = select.poll()
            for descriptor in observed:
                ready.register(descriptor, select.POLLIN)
            self.assertEqual({descriptor for descriptor, _ in ready.poll(0)}, set(observed))

    def test_setup_failure_reaps_the_daemon_before_session_dispatch(self):
        self.verify_failure("daemon-ready", RuntimeError("setup stopped"))

    def test_callback_failure_observes_daemon_and_pane_exit(self):
        self.verify_failure("pane-ready", RuntimeError("callback failed"))

    def test_callback_cancellation_observes_daemon_and_pane_exit(self):
        self.verify_failure("pane-ready", KeyboardInterrupt())

    def test_additional_panes_are_owned_on_success_failure_and_cancellation(self):
        for problem in [None, RuntimeError("created callback failed"), KeyboardInterrupt()]:
            with self.subTest(problem=type(problem).__name__), ExitStack() as owners:
                observed = []

                def observe(descriptors):
                    observed.append(len(descriptors))
                    self.assertEqual(len(descriptors), 3, "daemon and both pane processes must be owned")
                    exited(descriptors)

                def body():
                    with fixture(self.binary) as (socket, environment):
                        created = subprocess.run(
                            [self.binary, "-N", "-S", socket, "new-session", "-d", "-s", "extra",
                             "-P", "-F", "#{pane_pid}", "/bin/cat", "-"],
                            env=environment, capture_output=True, check=True, timeout=1)
                        descriptor = os.pidfd_open(int(created.stdout))
                        owners.callback(os.close, descriptor)
                        if problem is not None:
                            raise problem
                        return descriptor

                with patch("run.exited", observe):
                    if problem is None:
                        descriptor = body()
                        ready = select.poll()
                        ready.register(descriptor, select.POLLIN)
                        self.assertEqual(len(ready.poll(0)), 1)
                    else:
                        with self.assertRaises(type(problem)) as result:
                            body()
                        self.assertIs(result.exception, problem)
                        self.assertFalse(getattr(problem, "__notes__", []), "cleanup must be verified")
                self.assertEqual(observed, [3])

    def test_creation_cancellation_reports_the_untracked_pane(self):
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
                self.assertIsNotNone(socket, "startup must expose its owned endpoint")
                daemon = os.dup(descriptors[0])
                owners.callback(os.close, daemon)
                observed.append(daemon)
                environment = {key: value for key, value in os.environ.items()
                               if key not in {"TMUX", "TMUX_PANE"}}

                def command(*arguments):
                    return subprocess.run(
                        [self.binary, "-u", "-N", "-S", socket, *arguments],
                        env=environment, capture_output=True, check=True, timeout=1)

                command("set-hook", "-g", "after-new-session",
                        "wait-for -S example-created ; wait-for example-held")

                def interrupt_creation():
                    try:
                        command("wait-for", "example-created")
                        receipt = command("list-panes", "-a", "-F", "#{pane_pid}")
                        values = receipt.stdout.decode("ascii").split()
                        self.assertEqual(len(values), 1)
                        pane = os.pidfd_open(int(values[0]))
                        owners.callback(os.close, pane)
                        observed.append(pane)
                    except BaseException as problem:
                        problems.append(problem)
                    finally:
                        os.kill(os.getpid(), signal.SIGINT)

                monitor = threading.Thread(target=interrupt_creation)
                monitor.start()

            try:
                with self.assertRaises(KeyboardInterrupt) as result:
                    with fixture(self.binary, checkpoint):
                        self.fail("fixture yielded while session creation was held")
            finally:
                if monitor is not None:
                    monitor.join(timeout=1)
                    self.assertFalse(monitor.is_alive(), "creation monitor must join")
            self.assertEqual(problems, [])
            self.assertEqual(stages, ["daemon-ready"])
            self.assertEqual(len(observed), 2)
            self.assertEqual(result.exception.__notes__, [
                "owned fixture cleanup: session creation failed before pane exit ownership was established"
            ])
            ready = select.poll()
            for descriptor in observed:
                ready.register(descriptor, select.POLLIN)
            self.assertEqual({descriptor for descriptor, _ in ready.poll(0)}, set(observed))
            gc.collect()
            self.assertEqual([str(warning.message) for warning in emitted
                              if warning.category is ResourceWarning], [])

    def test_failed_command_retirement_does_not_enter_an_unbounded_wait(self):
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

        with patch("run.subprocess.Popen", FailedRead):
            try:
                with self.assertRaises(RuntimeError) as result:
                    with fixture(self.binary):
                        self.fail("fixture yielded after failed session response")
            finally:
                reaped = [client.returncode is not None for client in clients]
                for client in clients:
                    if client.poll() is None:
                        original.kill(client)
                    original.wait(client, timeout=1)
            self.assertIs(result.exception, primary)
            self.assertEqual(reaped, [True], "fixture must join its command child")
            self.assertIn("session command cleanup: command retirement failed",
                          primary.__notes__)


if __name__ == "__main__":
    unittest.main()
