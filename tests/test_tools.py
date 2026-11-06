"""Tool adapter tests with the mock APIs and Verified Permissions replaced by local fakes.

The fake Verified Permissions evaluates the real Cedar policies with cedarpy,
so these tests also prove the policies encode the business rules.
"""

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from conftest import make_token

cedarpy = pytest.importorskip("cedarpy")

ROOT = Path(__file__).resolve().parent.parent
CLAIMS = {c["claim_id"]: c for c in json.loads((ROOT / "services/claims_api/data/claims.json").read_text())}
POLICIES = {p["policy_id"]: p for p in json.loads((ROOT / "services/policy_api/data/policies.json").read_text())}
CEDAR_POLICIES = "\n".join(p.read_text() for p in sorted((ROOT / "policies").glob("*.cedar")))
SCHEMA = (ROOT / "policies/schema.json").read_text()


def _claims_of(token):
    import base64
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def _to_cedar_attrs(attrs):
    return {k: next(iter(v.values())) for k, v in attrs.items()}


class FakeAvp:
    """Evaluates requests the way Verified Permissions does for Cognito access tokens:
    principal is ClaimsAssist::User, token claims land in context.token."""

    def _evaluate(self, token, action, resource, entity_list):
        claims = _claims_of(token)
        entities = [{"uid": {"type": e["identifier"]["entityType"], "id": e["identifier"]["entityId"]},
                     "attrs": _to_cedar_attrs(e["attributes"]), "parents": []} for e in entity_list]
        entities.append({"uid": {"type": "ClaimsAssist::User", "id": claims["sub"]}, "attrs": {}, "parents": []})
        request = {
            "principal": f'ClaimsAssist::User::"{claims["sub"]}"',
            "action": f'{action["actionType"]}::"{action["actionId"]}"',
            "resource": f'{resource["entityType"]}::"{resource["entityId"]}"',
            "context": {"token": {k: claims[k] for k in ("population", "agency_id", "role", "region")}},
        }
        result = cedarpy.is_authorized(request, CEDAR_POLICIES, entities, schema=SCHEMA)
        return "ALLOW" if result.decision == cedarpy.Decision.Allow else "DENY"

    def is_authorized_with_token(self, policyStoreId, accessToken, action, resource, entities):
        return {"decision": self._evaluate(accessToken, action, resource, entities["entityList"]),
                "determiningPolicies": []}

    def batch_is_authorized_with_token(self, policyStoreId, accessToken, entities, requests):
        return {"results": [{"request": r,
                             "decision": self._evaluate(accessToken, r["action"], r["resource"],
                                                        entities["entityList"])}
                            for r in requests]}


def fake_api(path, token):
    """Mimics the mock APIs, including their broker backstop."""
    who = _claims_of(token)

    def visible(rec):
        return who["population"] != "broker" or (who["agency_id"] and rec["agency_id"] == who["agency_id"])

    if path.startswith("/claims/"):
        rec = CLAIMS.get(path.rsplit("/", 1)[1])
        return rec if rec and visible(rec) else None
    if path.startswith("/claims?"):
        return {"items": [c for c in CLAIMS.values() if visible(c)]}
    if path.startswith("/policies/"):
        rec = POLICIES.get(path.rsplit("/", 1)[1])
        return rec if rec and visible(rec) else None
    raise AssertionError(path)


@pytest.fixture
def tools(monkeypatch):
    spec = importlib.util.spec_from_file_location("tools", ROOT / "lambdas/tools/handler.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    monkeypatch.setattr(mod, "avp", FakeAvp())
    monkeypatch.setattr(mod, "_get", fake_api)
    return mod


def ctx(tool):
    return SimpleNamespace(client_context=SimpleNamespace(custom={
        "bedrockAgentCoreToolName": f"claims___{tool}",
        "bedrockAgentCoreAwsRequestId": "req-1",
        "bedrockAgentCoreMcpMessageId": "7",
    }))


USERS = {
    "adjuster.north": dict(population="staff", role="claims-adjuster", region="north", agency_id=""),
    "senior.north": dict(population="staff", role="claims-senior-adjuster", region="north", agency_id=""),
    "senior.south": dict(population="staff", role="claims-senior-adjuster", region="south", agency_id=""),
    "broker.ag100": dict(population="broker", role="broker", region="", agency_id="AG-100"),
    "broker.ag200": dict(population="broker", role="broker", region="", agency_id="AG-200"),
}

# (user, claim, visible?) — the README test matrix.
MATRIX = [
    ("adjuster.north", "CLM-1001", True),   # own region
    ("adjuster.north", "CLM-1005", True),   # own region, any agency
    ("adjuster.north", "CLM-1003", False),  # other region
    ("senior.north", "CLM-1004", False),    # fraud case, but other region
    ("senior.south", "CLM-1004", True),     # fraud case, senior, own region
    ("senior.south", "CLM-1006", True),
    ("broker.ag100", "CLM-1001", True),     # own agency
    ("broker.ag100", "CLM-1003", False),    # other agency (stopped by the API backstop)
    ("broker.ag100", "CLM-1004", False),    # own agency but under fraud investigation (Cedar forbid)
    ("broker.ag200", "CLM-1001", False),
    ("broker.ag200", "CLM-1006", False),    # fraud case
]


@pytest.mark.parametrize("user,claim_id,visible", MATRIX)
def test_get_claim_matrix(tools, user, claim_id, visible):
    out = tools.handler({"claim_id": claim_id, "_caller_token": make_token(**USERS[user])}, ctx("get_claim"))
    if visible:
        assert out["claim_id"] == claim_id
        assert "agency_id" not in out and "under_investigation" not in out  # projection only
    else:
        assert out == tools.NOT_ACCESSIBLE


def test_denied_and_missing_look_identical(tools):
    token = make_token(**USERS["broker.ag100"])
    denied = tools.handler({"claim_id": "CLM-1004", "_caller_token": token}, ctx("get_claim"))
    missing = tools.handler({"claim_id": "CLM-9999", "_caller_token": token}, ctx("get_claim"))
    assert denied == missing


def test_search_filters_with_batch_authorization(tools):
    out = tools.handler({"_caller_token": make_token(**USERS["broker.ag100"])}, ctx("search_claims"))
    assert {c["claim_id"] for c in out["items"]} == {"CLM-1001", "CLM-1002"}


def test_policy_rules(tools):
    token = make_token(**USERS["adjuster.north"])
    assert tools.handler({"policy_id": "POL-2004", "_caller_token": token}, ctx("get_policy"))["policy_id"] == "POL-2004"
    assert tools.handler({"policy_id": "POL-2002", "_caller_token": token}, ctx("get_policy")) == tools.NOT_ACCESSIBLE


def test_missing_identity_fails_closed(tools):
    out = tools.handler({"claim_id": "CLM-1001"}, ctx("get_claim"))
    assert out == {"error": "Caller identity unavailable."}


def test_rejects_malformed_ids(tools):
    out = tools.handler({"claim_id": "../admin", "_caller_token": make_token()}, ctx("get_claim"))
    assert "error" in out


def test_audit_line_names_the_human(tools, caplog):
    caplog.set_level("INFO")
    tools.handler({"claim_id": "CLM-1001", "_caller_token": make_token(username="jo.adjuster",
                                                                       **USERS["adjuster.north"])},
                  ctx("get_claim"))
    line = next(json.loads(r.message) for r in caplog.records if "authz_decision" in r.message)
    assert line["username"] == "jo.adjuster" and line["decision"] == "ALLOW"
    assert line["resources"] == ["CLM-1001"] and line["gateway_request_id"] == "req-1"


def test_policies_validate_against_schema():
    result = cedarpy.validate_policies(CEDAR_POLICIES, SCHEMA)
    assert result.validation_passed, result.errors
