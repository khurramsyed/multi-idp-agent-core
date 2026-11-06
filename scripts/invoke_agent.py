#!/usr/bin/env python3
"""Talk to the claims agent on AgentCore Runtime as a given test user.

    python scripts/invoke_agent.py --user adjuster.north "What is the status of claim CLM-1001?"
    python scripts/invoke_agent.py --user broker.ag200   "Summarise claim CLM-1001 for me"
"""

import argparse
import getpass
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import uuid

from _common import sign_in, tf_outputs


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--user", required=True)
    p.add_argument("--session", help="Reuse a session ID to keep conversation context")
    p.add_argument("prompt")
    a = p.parse_args()

    password = os.environ.get("TEST_USER_PASSWORD") or getpass.getpass(f"Password for {a.user}: ")
    out = tf_outputs()
    token = sign_in(out, a.user, password)

    arn = urllib.parse.quote(out["agent_runtime_arn"], safe="")
    url = f"https://bedrock-agentcore.{out['region']}.amazonaws.com/runtimes/{arn}/invocations?qualifier=DEFAULT"
    session = a.session or str(uuid.uuid4())  # must be at least 33 characters

    req = urllib.request.Request(
        url,
        data=json.dumps({"prompt": a.prompt}).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"HTTP {exc.code}: {exc.read().decode()}") from exc

    try:
        data = json.loads(body)
        print(data.get("result", data) if isinstance(data, dict) else data)
    except ValueError:
        print(body)
    print(f"\n(session {session})")


if __name__ == "__main__":
    main()
