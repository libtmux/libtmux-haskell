"""Critical failure and cancellation checks for the owned example fixture."""

from contextlib import ExitStack
import os
import select
import shutil
import unittest

from run import fixture


class FixtureChecks(unittest.TestCase):
    def setUp(self):
        self.binary = shutil.which(os.environ.get("LIBTMUX_TEST_TMUX", "tmux"))
        self.assertIsNotNone(self.binary, "select an installed tmux release")

    def verify_failure(self, stage, problem):
        with ExitStack() as owners:
            observed = []

            def checkpoint(current, descriptors):
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


if __name__ == "__main__":
    unittest.main()
