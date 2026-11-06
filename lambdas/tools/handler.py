"""Thin tool adapters behind AgentCore Gateway: fetch, decide, release.

One Lambda serves three MCP tools: get_claim, search_claims and get_policy.
For every record the flow is the same:

  1. Read the end user's token from the reserved argument the interceptor injected.
  2. Fetch the record from the system of record (mock APIs on ECS Fargate),
     forwarding the user's token — the API validates it independently.
  3. Ask Amazon Verified Permissions whether this user may read this record.
  4. Release a projection of the record only on ALLOW, and write an audit line.

Denied and missing records return the same message, so the agent can never
reveal that a record it may not see exists.
"""

import base64
import json
import logging
import os
import re
import urllib.error
import urllib.parse
import urllib.request

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

POLICY_STORE_ID = os.environ["POLICY_STORE_ID"]
API_BASE_URL = os.environ["API_BASE_URL"].rstrip("/")
RESERVED_ARG = os.environ.get("RESERVED_ARG", "_caller_token")
NAMESPACE = "ClaimsAssist"
HTTP_TIMEOUT = 5
AVP_BATCH_LIMIT = 30

ID_PATTERN = re.compile(r"^[A-Z]{3}-\d{4}$")
NOT_ACCESSIBLE = {"error": "Record not found or not accessible."}

# Only these fields ever reach the model.
CLAIM_FIELDS = ("claim_id", "policy_id", "status", "loss_type", "loss_date",
                "summary", "investigator_notes", "next_steps")
POLICY_FIELDS = ("policy_id", "insured", "product", "status", "period", "cover",
                 "key_conditions")

avp = boto3.client("verifiedpermissions")


# ---------------------------------------------------------------- helpers ---

class UpstreamError(Exception):
    pass


def _tool_name(context) -> str | None:
    """Gateway prefixes tool names with the target name, e.g. claims___get_claim."""
    try:
        full = context.client_context.custom["bedrockAgentCoreToolName"]
    except (AttributeError, KeyError, TypeError):
        return None
    for name in TOOLS:
        if full == name or full.endswith("_" + name):
            return name
    return None


def _gateway_meta(context) -> dict:
    try:
        custom = context.client_context.custom or {}
    except AttributeError:
        custom = {}
    return {"gateway_request_id": custom.get("bedrockAgentCoreAwsRequestId"),
            "mcp_message_id": custom.get("bedrockAgentCoreMcpMessageId")}


def _unverified_claims(token: str) -> dict:
    """For audit logging only. Verified Permissions validates the token itself."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError):
        return {}


def _get(path: str, token: str) -> dict | None:
    """GET from the system of record. Returns None for 403/404."""
    req = urllib.request.Request(
        f"{API_BASE_URL}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        if exc.code in (403, 404):
            return None
        raise UpstreamError(f"upstream returned {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise UpstreamError("upstream unavailable") from exc


def _claim_entity(c: dict) -> dict:
    return {
        "identifier": {"entityType": f"{NAMESPACE}::Claim", "entityId": c["claim_id"]},
        "attributes": {
            "agencyId": {"string": c["agency_id"]},
            "region": {"string": c["region"]},
            "policyId": {"string": c["policy_id"]},
            "underInvestigation": {"boolean": bool(c["under_investigation"])},
        },
    }


def _policy_entity(p: dict) -> dict:
    return {
        "identifier": {"entityType": f"{NAMESPACE}::Policy", "entityId": p["policy_id"]},
        "attributes": {
            "agencyId": {"string": p["agency_id"]},
            "region": {"string": p["region"]},
        },
    }


def _action(name: str) -> dict:
    return {"actionType": f"{NAMESPACE}::Action", "actionId": name}


def _decide_one(token: str, action: str, entity: dict) -> tuple[str, list[str]]:
    resp = avp.is_authorized_with_token(
        policyStoreId=POLICY_STORE_ID,
        accessToken=token,
        action=_action(action),
        resource=entity["identifier"],
        entities={"entityList": [entity]},
    )
    return resp["decision"], [p["policyId"] for p in resp.get("determiningPolicies", [])]


def _decide_many(token: str, action: str, entities: list[dict]) -> dict[str, str]:
    """Batch authorization for list-returning tools. Returns {entityId: decision}."""
    decisions: dict[str, str] = {}
    for i in range(0, len(entities), AVP_BATCH_LIMIT):
        chunk = entities[i:i + AVP_BATCH_LIMIT]
        resp = avp.batch_is_authorized_with_token(
            policyStoreId=POLICY_STORE_ID,
            accessToken=token,
            entities={"entityList": chunk},
            requests=[{"action": _action(action), "resource": e["identifier"]} for e in chunk],
        )
        for result in resp["results"]:
            decisions[result["request"]["resource"]["entityId"]] = result["decision"]
    return decisions


def _audit(meta: dict, who: dict, tool: str, resources: list[str], decision: str,
           policies: list[str] | None = None) -> None:
    log.info(json.dumps({
        "event": "authz_decision",
        "tool": tool,
        "sub": who.get("sub"),
        "username": who.get("username"),
        "population": who.get("population"),
        "agency_id": who.get("agency_id"),
        "role": who.get("role"),
        "resources": resources,
        "decision": decision,
        "determining_policies": policies or [],
        **meta,
    }))


def _project(record: dict, fields: tuple) -> dict:
    return {k: record[k] for k in fields if k in record}


# ------------------------------------------------------------------ tools ---

def get_claim(args: dict, token: str, who: dict, meta: dict) -> dict:
    claim_id = str(args.get("claim_id", "")).strip().upper()
    if not ID_PATTERN.match(claim_id):
        return {"error": "claim_id must look like CLM-1234."}

    claim = _get(f"/claims/{urllib.parse.quote(claim_id)}", token)
    if claim is None:
        _audit(meta, who, "get_claim", [claim_id], "NOT_FOUND")
        return NOT_ACCESSIBLE

    decision, policies = _decide_one(token, "ReadClaim", _claim_entity(claim))
    _audit(meta, who, "get_claim", [claim_id], decision, policies)
    return _project(claim, CLAIM_FIELDS) if decision == "ALLOW" else NOT_ACCESSIBLE


def search_claims(args: dict, token: str, who: dict, meta: dict) -> dict:
    query = {}
    policy_id = str(args.get("policy_id") or "").strip().upper()
    if policy_id:
        if not ID_PATTERN.match(policy_id):
            return {"error": "policy_id must look like POL-1234."}
        query["policy_id"] = policy_id
    if args.get("status"):
        query["status"] = str(args["status"]).strip().upper()[:32]

    result = _get(f"/claims?{urllib.parse.urlencode(query)}", token) or {"items": []}
    claims = result.get("items", [])
    if not claims:
        _audit(meta, who, "search_claims", [], "EMPTY")
        return {"items": [], "count": 0}

    decisions = _decide_many(token, "ReadClaim", [_claim_entity(c) for c in claims])
    allowed = [c for c in claims if decisions.get(c["claim_id"]) == "ALLOW"]
    for c in claims:
        _audit(meta, who, "search_claims", [c["claim_id"]], decisions.get(c["claim_id"], "DENY"))
    return {"items": [_project(c, ("claim_id", "policy_id", "status", "loss_type", "loss_date"))
                      for c in allowed],
            "count": len(allowed)}


def get_policy(args: dict, token: str, who: dict, meta: dict) -> dict:
    policy_id = str(args.get("policy_id", "")).strip().upper()
    if not ID_PATTERN.match(policy_id):
        return {"error": "policy_id must look like POL-1234."}

    policy = _get(f"/policies/{urllib.parse.quote(policy_id)}", token)
    if policy is None:
        _audit(meta, who, "get_policy", [policy_id], "NOT_FOUND")
        return NOT_ACCESSIBLE

    decision, policies = _decide_one(token, "ReadPolicy", _policy_entity(policy))
    _audit(meta, who, "get_policy", [policy_id], decision, policies)
    return _project(policy, POLICY_FIELDS) if decision == "ALLOW" else NOT_ACCESSIBLE


TOOLS = {"get_claim": get_claim, "search_claims": search_claims, "get_policy": get_policy}


# ---------------------------------------------------------------- handler ---

def handler(event, context):
    event = dict(event or {})
    token = event.pop(RESERVED_ARG, None)
    meta = _gateway_meta(context)

    if not token:
        # The interceptor did not run or the gateway dropped the argument: fail closed.
        log.error(json.dumps({"event": "missing_caller_identity", **meta}))
        return {"error": "Caller identity unavailable."}

    tool = _tool_name(context)
    if tool is None:
        log.error(json.dumps({"event": "unknown_tool", **meta}))
        return {"error": "Unknown tool."}

    who = _unverified_claims(token)
    try:
        return TOOLS[tool](event, token, who, meta)
    except UpstreamError as exc:
        log.error(json.dumps({"event": "upstream_error", "tool": tool, "detail": str(exc), **meta}))
        return {"error": "The claims systems are temporarily unavailable. Please try again."}
