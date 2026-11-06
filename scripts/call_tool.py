#!/usr/bin/env python3
"""Call AgentCore Gateway tools directly as a given user — no model involved.

This is the fastest way to prove the authorization chain:

    python scripts/call_tool.py --user broker.ag100 list
    python scripts/call_tool.py --user broker.ag100 get_claim claim_id=CLM-1001   # own agency: allowed
    python scripts/call_tool.py --user broker.ag100 get_claim claim_id=CLM-1003   # other agency: not accessible
    python scripts/call_tool.py --user broker.ag100 get_claim claim_id=CLM-1001 _caller_token=forged
"""

import argparse
import getpass
import json
import os
import urllib.error
import urllib.request

from _common import sign_in, tf_outputs

PROTOCOL_VERSION = "2025-03-26"


class Mcp:
    def __init__(self, url: str, token: str):
        self.url = url if url.rstrip("/").endswith("/mcp") else url.rstrip("/") + "/mcp"
        self.token = token
        self.session = None
        self.next_id = 1

    def _post(self, body: dict) -> dict | None:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": PROTOCOL_VERSION,
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                self.session = resp.headers.get("Mcp-Session-Id") or self.session
                ctype = resp.headers.get("Content-Type", "")
                raw = resp.read().decode()
        except urllib.error.HTTPError as exc:
            raise SystemExit(f"HTTP {exc.code}: {exc.read().decode()}") from exc
        if not raw.strip():
            return None
        if "text/event-stream" in ctype:
            events = [line[5:].strip() for line in raw.splitlines() if line.startswith("data:")]
            return json.loads(events[-1]) if events else None
        return json.loads(raw)

    def request(self, method: str, params: dict | None = None) -> dict:
        body = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        self.next_id += 1
        if params is not None:
            body["params"] = params
        return self._post(body)

    def notify(self, method: str) -> None:
        self._post({"jsonrpc": "2.0", "method": method})

    def connect(self) -> None:
        self.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "claims-assist-cli", "version": "1.0"},
        })
        self.notify("notifications/initialized")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--user", required=True)
    p.add_argument("tool", help="'list' or a tool name such as get_claim")
    p.add_argument("args", nargs="*", help="key=value tool arguments")
    a = p.parse_args()

    password = os.environ.get("TEST_USER_PASSWORD") or getpass.getpass(f"Password for {a.user}: ")
    out = tf_outputs()
    mcp = Mcp(out["gateway_url"], sign_in(out, a.user, password))
    mcp.connect()

    tools = mcp.request("tools/list")["result"]["tools"]
    if a.tool == "list":
        for t in tools:
            print(f"{t['name']:40} {t.get('description', '')}")
        return

    full = next((t["name"] for t in tools if t["name"] == a.tool or t["name"].endswith("_" + a.tool)), None)
    if not full:
        raise SystemExit(f"No tool named {a.tool}. Try 'list'.")
    arguments = dict(kv.split("=", 1) for kv in a.args)
    print(json.dumps(mcp.request("tools/call", {"name": full, "arguments": arguments}), indent=2))


if __name__ == "__main__":
    main()
