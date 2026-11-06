#!/usr/bin/env python3
"""Post-deploy smoke test: proves the authorization chain on the deployed stack.

Signs in as each test user, calls get_claim through AgentCore Gateway (no model
involved) and asserts who can read which claim record. It also checks that a
forged _caller_token is ignored, and fails loudly if the reserved argument never
reaches the tool Lambda.

    export TEST_USER_PASSWORD=...
    python scripts/smoke_test.py
"""

import json
import os
import sys

from _common import sign_in, tf_outputs
from call_tool import Mcp

# (user, claim, expected visible), from the Cedar policies and the API backstop.
EXPECTED = [
    ("adjuster.north", "CLM-1001", True),
    ("adjuster.north", "CLM-1003", False),
    ("adjuster.north", "CLM-1004", False),
    ("adjuster.north", "CLM-1005", True),
    ("senior.north", "CLM-1001", True),
    ("senior.north", "CLM-1003", False),
    ("senior.north", "CLM-1004", False),
    ("senior.north", "CLM-1005", True),
    ("senior.south", "CLM-1001", False),
    ("senior.south", "CLM-1003", True),
    ("senior.south", "CLM-1004", True),
    ("senior.south", "CLM-1005", False),
    ("broker.ag100", "CLM-1001", True),
    ("broker.ag100", "CLM-1003", False),
    ("broker.ag100", "CLM-1004", False),
    ("broker.ag100", "CLM-1005", False),
    ("broker.ag200", "CLM-1001", False),
    ("broker.ag200", "CLM-1003", True),
    ("broker.ag200", "CLM-1004", False),
    ("broker.ag200", "CLM-1005", True),
]


def tool_payload(response: dict) -> dict:
    """Return the tool Lambda's JSON result from an MCP tools/call response."""
    if "error" in response:
        return {"error": response["error"].get("message", "gateway error")}
    content = response.get("result", {}).get("content", [])
    text = content[0].get("text", "") if content else ""
    try:
        return json.loads(text)
    except ValueError:
        return {"error": text or "empty response"}


def main() -> int:
    password = os.environ.get("TEST_USER_PASSWORD")
    if not password:
        sys.exit("Set TEST_USER_PASSWORD (the password used by create_test_users.sh).")
    outputs = tf_outputs()
    sessions: dict[str, tuple[Mcp, str]] = {}
    failures = 0

    def session(user: str) -> tuple[Mcp, str]:
        if user not in sessions:
            mcp = Mcp(outputs["gateway_url"], sign_in(outputs, user, password))
            mcp.connect()
            tools = mcp.request("tools/list")["result"]["tools"]
            name = next(t["name"] for t in tools if t["name"].endswith("get_claim"))
            sessions[user] = (mcp, name)
        return sessions[user]

    def call(user: str, claim: str, extra: dict | None = None) -> dict:
        mcp, name = session(user)
        args = {"claim_id": claim, **(extra or {})}
        return tool_payload(mcp.request("tools/call", {"name": name, "arguments": args}))

    # 1. The identity hand-off works at all.
    first = call("adjuster.north", "CLM-1001")
    if first.get("error") == "Caller identity unavailable.":
        print("FAIL  The gateway did not pass _caller_token to the Lambda target.")
        print("      Declare _caller_token in each tool's input_schema (see README troubleshooting).")
        return 1

    # 2. The access grid.
    for user, claim, visible in EXPECTED:
        result = call(user, claim)
        got = result.get("claim_id") == claim
        ok = got == visible
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'}  {user:15} {claim}  expected {'visible' if visible else 'hidden '}"
              f"  got {'visible' if got else 'hidden '}"
              + ("" if ok or got else f"  ({result.get('error')})"))

    # 3. A broker smuggles a senior adjuster's real token into the reserved argument.
    #    If the interceptor did not overwrite it, the broker would see the fraud case.
    smuggled = sign_in(outputs, "senior.south", password)
    forged = call("broker.ag100", "CLM-1004", {"_caller_token": smuggled})
    ok = forged.get("claim_id") != "CLM-1004"
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'}  a smuggled _caller_token is overwritten by the interceptor")

    print(f"\n{len(EXPECTED) + 1 - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
