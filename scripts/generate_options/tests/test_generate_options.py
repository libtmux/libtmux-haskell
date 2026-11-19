"""Validate macro expansion, timeline changes and parser refusals."""

from pathlib import Path

import pytest

from generate_options import Entry, histories, parse, preprocess


@pytest.fixture
def source() -> bytes:
    """A table containing an expanded hook and one option with choices."""
    return b"""
#define AFTER(hook_name) { .name = "after-" hook_name, .type = OPTIONS_TABLE_COMMAND, \\
  .scope = OPTIONS_TABLE_SESSION, .flags = OPTIONS_TABLE_IS_ARRAY|OPTIONS_TABLE_IS_HOOK }
static const char *options_table_modes_list[] = { "on", "off", NULL };
const struct options_table_entry options_table[] = {
  { .name = "mode", .type = OPTIONS_TABLE_CHOICE, .scope = OPTIONS_TABLE_WINDOW,
    .choices = options_table_modes_list, .text = "Commas, braces } and quotes \\" stay in text." },
  AFTER("example"),
  { .name = NULL }
};
"""


def test_c_macro_supplies_scope_and_name(source: bytes, tmp_path: Path) -> None:
    table = tmp_path / "options.c"
    entries = parse(preprocess(source, "cc", table))
    assert entries["mode"].choices == ("on", "off")
    assert entries["after-example"].scopes == ("SESSION",)
    amended = source.replace(b"OPTIONS_TABLE_SESSION", b"OPTIONS_TABLE_WINDOW|OPTIONS_TABLE_PANE")
    changed = parse(preprocess(amended, "cc", table))
    assert changed["after-example"].scopes == ("WINDOW", "PANE")


def test_rejects_changes_that_need_a_new_parser(source: bytes, tmp_path: Path) -> None:
    table = tmp_path / "options.c"
    no_sentinel = source.replace(b"  { .name = NULL }", b"")
    with pytest.raises(ValueError, match="sentinel"):
        parse(preprocess(no_sentinel, "cc", table))
    new_flag = source.replace(b"OPTIONS_TABLE_IS_HOOK", b"OPTIONS_TABLE_NOT_REVIEWED")
    with pytest.raises(ValueError, match="unsupported"):
        parse(preprocess(new_flag, "cc", table))
    with pytest.raises(ValueError, match="conditional C definitions"):
        preprocess(b"#ifdef ENABLE_OPTION\n" + source + b"#endif", "cc", table)


def test_history_retains_type_changes_and_absence() -> None:
    flag = Entry("FLAG", ("SERVER",), frozenset(), ())
    choice = Entry("CHOICE", ("SERVER",), frozenset(), ("on", "off", "auto"))
    assert histories(
        [
            ("3.3a", {"mode": flag}),
            ("3.4", {"mode": choice}),
            ("3.5", {}),
            ("3.6", {"mode": flag}),
        ]
    ) == {
        "mode": [
            ("3.3a", ("3.3a", flag)),
            ("3.4", ("3.3a", choice)),
            ("3.5", None),
            ("3.6", ("3.6", flag)),
        ]
    }
