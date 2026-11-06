"""The post-deploy smoke test's expected access grid must match the real policies.

This runs the full 5 x 4 grid from scripts/smoke_test.py through the tool Lambda,
with real Cedar evaluation and the API backstop, so a policy change that would make
the deployed smoke test fail is caught in CI first.
"""

import sys
from pathlib import Path

import pytest

from conftest import make_token
from test_tools import USERS, ctx, tools  # noqa: F401  (tools is a fixture)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from smoke_test import EXPECTED  # noqa: E402


@pytest.mark.parametrize("user,claim_id,visible", EXPECTED)
def test_smoke_expectations_match_policies(tools, user, claim_id, visible):  # noqa: F811
    out = tools.handler({"claim_id": claim_id, "_caller_token": make_token(**USERS[user])}, ctx("get_claim"))
    assert (out.get("claim_id") == claim_id) is visible


def test_grid_covers_every_user_and_claim():
    users = {u for u, _, _ in EXPECTED}
    claims = {c for _, c, _ in EXPECTED}
    assert users == set(USERS)
    assert len(EXPECTED) == len(users) * len(claims)
