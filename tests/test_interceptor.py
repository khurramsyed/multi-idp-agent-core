import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest

from conftest import OTHER_KEY, PRIVATE_KEY, make_token

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def interceptor(monkeypatch):
    spec = importlib.util.spec_from_file_location("interceptor", ROOT / "lambdas/interceptor/handler.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    fake_key = SimpleNamespace(key=PRIVATE_KEY.public_key())
    monkeypatch.setattr(mod._jwks, "get_signing_key_from_jwt", lambda token: fake_key)
    return mod


def call_event(token=None, arguments=None, method="tools/call"):
    headers = {"Mcp-Session-Id": "s1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = {"jsonrpc": "2.0", "id": 7, "method": method}
    if method == "tools/call":
        body["params"] = {"name": "claims___get_claim", "arguments": arguments or {"claim_id": "CLM-1001"}}
    return {"interceptorInputVersion": "1.0",
            "mcp": {"gatewayRequest": {"path": "/mcp", "httpMethod": "POST", "headers": headers, "body": body}}}


def test_injects_verified_token(interceptor):
    token = make_token()
    out = interceptor.handler(call_event(token), None)
    args = out["mcp"]["transformedGatewayRequest"]["body"]["params"]["arguments"]
    assert args["_caller_token"] == token
    assert args["claim_id"] == "CLM-1001"


def test_overwrites_forged_reserved_argument(interceptor):
    token = make_token()
    out = interceptor.handler(call_event(token, {"claim_id": "CLM-1", "_caller_token": "forged"}), None)
    assert out["mcp"]["transformedGatewayRequest"]["body"]["params"]["arguments"]["_caller_token"] == token


def test_non_tool_calls_pass_through(interceptor):
    out = interceptor.handler(call_event(method="tools/list"), None)
    assert out["mcp"]["transformedGatewayRequest"]["body"]["method"] == "tools/list"


def test_missing_header_short_circuits(interceptor):
    out = interceptor.handler(call_event(None), None)
    resp = out["mcp"]["transformedGatewayResponse"]
    assert resp["statusCode"] == 401 and resp["body"]["id"] == 7
    assert "transformedGatewayRequest" not in out["mcp"]


@pytest.mark.parametrize("token", [
    make_token(key=OTHER_KEY),
    make_token(token_use="id"),
    make_token(client_id="other-client"),
])
def test_bad_tokens_short_circuit(interceptor, token):
    out = interceptor.handler(call_event(token), None)
    assert out["mcp"]["transformedGatewayResponse"]["statusCode"] == 401
