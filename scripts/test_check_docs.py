"""Verify that documentation checks reject defects in disposable copies."""

import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import check_docs


class DocumentationChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="libtmux-haskell-docs-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ["docs", ".github", "examples", "bench", "src", "internal", "scripts", "test"]:
            shutil.copytree(check_docs.ROOT / directory, self.root / directory,
                            ignore=shutil.ignore_patterns("__pycache__", "dist-newstyle"))
        for filename in ["README.md", "AGENTS.md", "LICENSE", ".tool-versions", "libtmux-haskell.cabal"]:
            shutil.copy2(check_docs.ROOT / filename, self.root / filename)
        for name, value in [("ROOT", self.root), ("CATALOGUE", self.root / "examples/catalogue.json")]:
            context = patch.object(check_docs, name, value)
            context.start()
            self.addCleanup(context.stop)

    def test_registered_program_is_valid(self):
        self.assertEqual({entry["id"] for entry in check_docs.check()},
                         {"typed-values", "capture-graph", "offline-graph", "shared-runtime", "query-graph", "mutate-graph", "create-session"})

    def test_unregistered_haskell_fence_is_rejected(self):
        with (self.root / "README.md").open("a") as document:
            document.write("\n```haskell\nmain = pure ()\n```\n")
        with self.assertRaisesRegex(ValueError, "Unregistered Haskell"):
            check_docs.check()

    def test_nested_guide_is_checked(self):
        guide = self.root / "docs/tasks/new.md"
        guide.parent.mkdir()
        guide.write_text("~~~hs\nmain = pure ()\n~~~\n")
        with self.assertRaisesRegex(ValueError, "Unregistered Haskell"):
            check_docs.check()

    def test_undeclared_source_is_rejected(self):
        (self.root / "examples/typed-values/Helper.hs").write_text("module Helper where\n")
        with self.assertRaisesRegex(ValueError, "Declared and discovered"):
            check_docs.check()

    def test_stale_snippet_is_rejected(self):
        path = self.root / "docs/values.md"
        path.write_text(path.read_text().replace('parseWindowId "@17"', 'parseWindowId "@18"'))
        with self.assertRaisesRegex(ValueError, "differs from its source"):
            check_docs.check()

    def test_missing_html_logo_is_rejected(self):
        path = self.root / "README.md"
        original = path.read_text()
        for markup in ['<img src="docs/assets/missing.png" alt="Missing logo">',
                       '<source srcset="docs/assets/missing.svg" type="image/svg+xml">']:
            with self.subTest(markup=markup):
                path.write_text(original + "\n" + markup + "\n")
                with self.assertRaisesRegex(ValueError, "Broken local link"):
                    check_docs.check()

    def test_empty_catalogue_is_rejected(self):
        path = self.root / "examples/catalogue.json"
        document = json.loads(path.read_text())
        document["examples"] = []
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(ValueError, "No declared examples"):
            check_docs.check()

    def test_unknown_schema_is_rejected(self):
        path = self.root / "examples/catalogue.json"
        document = json.loads(path.read_text())
        document["schema"] = "libtmux.examples/unknown"
        path.write_text(json.dumps(document))
        with self.assertRaisesRegex(ValueError, "Unknown example catalogue"):
            check_docs.check()

    def test_stale_workflow_locator_is_rejected(self):
        path = self.root / "examples/catalogue.json"
        original = json.loads(path.read_text())
        for key, value in [("job", "missing-job"), ("step", "Missing step"),
                           ("command", ["python3", "scripts/missing.py"])]:
            with self.subTest(key=key):
                document = json.loads(json.dumps(original))
                document["examples"][0]["verification"][key] = value
                path.write_text(json.dumps(document))
                with self.assertRaisesRegex(ValueError, "Example workflow"):
                    check_docs.check()

    def test_runner_and_command_stay_bound_to_the_example(self):
        path = self.root / "examples/catalogue.json"
        original = json.loads(path.read_text())
        for key, value, message in [
            ("runner", "scripts/check_docs.py", "runner must belong"),
            ("command", ["python3", "scripts/check_docs.py"], "command must execute"),
        ]:
            with self.subTest(key=key):
                document = json.loads(json.dumps(original))
                document["examples"][1][key] = value
                path.write_text(json.dumps(document))
                with self.assertRaisesRegex(ValueError, message):
                    check_docs.check()

    def test_shared_runner_binds_the_declared_program_and_output(self):
        path = self.root / "examples/catalogue.json"
        document = json.loads(path.read_text())
        entry = document["examples"][2]
        entry["runner"] = "examples/capture-graph/run.py"
        entry["command"] = ["python3", entry["runner"], "--executable", entry["executable"],
                            "--expected-output", entry["stdout"]]
        original = json.dumps(document)
        path.write_text(original)
        try:
            check_docs.check()
        except ValueError as problem:
            self.fail(f"Declared shared fixture was rejected: {problem}")

        for index, value in [(3, "capture-graph"),
                             (5, "examples/capture-graph/expected.stdout")]:
            with self.subTest(argument=index):
                changed = json.loads(original)
                changed["examples"][2]["command"][index] = value
                path.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, "command must execute"):
                    check_docs.check()


if __name__ == "__main__":
    unittest.main()
