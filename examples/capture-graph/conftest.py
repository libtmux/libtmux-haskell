"""Released tmux selection for example fixture and README checks."""

import os
import shutil

import pytest


@pytest.fixture
def tmux_binary() -> str:
    selected = os.environ.get("LIBTMUX_TEST_TMUX")
    assert selected, "set LIBTMUX_TEST_TMUX to a released tmux binary"
    binary = shutil.which(selected)
    assert binary is not None, "select an installed tmux release"
    return binary
