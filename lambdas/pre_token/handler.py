"""Cognito pre token generation trigger (event version V2_0).

Turns two identity worlds into one token shape. Every access token leaves
Cognito with the same four claims, whichever IdP the user signed in with:

    population  "staff" | "broker"
    agency_id   broker's agency, "" for staff
    role        staff role from IdP groups, "broker" for brokers
    region      staff region, "" for brokers

All four are always present so Cedar policies never need "has" checks.

Rules this function follows:
  * Values come only from attributes the IdP asserted (custom:idp_*), or, for
    admin-created test users, from admin-only attributes (custom:t_*).
  * Anything unexpected fails the sign-in. A token that can do nothing is
    harder to support than a clear sign-in error.
"""

import json
import logging
import os

log = logging.getLogger()
log.setLevel(logging.INFO)

WORKFORCE_PROVIDER = os.environ.get("WORKFORCE_PROVIDER_NAME", "Workforce")
BROKER_PROVIDER = os.environ.get("BROKER_PROVIDER_NAME", "Brokers")
ALLOW_TEST_USERS = os.environ.get("ALLOW_TEST_USERS", "false").lower() == "true"
STAFF_ROLES = set(
    os.environ.get("STAFF_ROLES", "claims-adjuster,claims-senior-adjuster").split(",")
)
API_SCOPE = os.environ.get("API_SCOPE", "claims-api/claims.read")


class SignInRejected(Exception):
    """Raised to make Cognito fail the sign-in."""


def _provider_name(attrs: dict) -> str | None:
    raw = attrs.get("identities")
    if not raw:
        return None
    try:
        identities = json.loads(raw)
    except ValueError:
        return None
    return identities[0].get("providerName") if identities else None


def _parse_groups(raw: str | None) -> list[str]:
    """IdPs send groups as a JSON array or a comma-separated string."""
    if not raw:
        return []
    try:
        value = json.loads(raw)
        if isinstance(value, list):
            return [str(g).strip() for g in value if str(g).strip()]
    except ValueError:
        pass
    return [g.strip() for g in raw.strip("[]").split(",") if g.strip()]


def _broker(agency: str) -> dict:
    agency = (agency or "").strip()
    if not agency:
        raise SignInRejected("Broker identity has no agency")
    return {"population": "broker", "agency_id": agency, "role": "broker", "region": ""}


def _staff(role: str | None, region: str) -> dict:
    region = (region or "").strip().lower()
    if role not in STAFF_ROLES:
        raise SignInRejected("Staff identity has no claims role")
    if not region:
        raise SignInRejected("Staff identity has no region")
    return {"population": "staff", "agency_id": "", "role": role, "region": region}


def build_claims(attrs: dict) -> dict:
    provider = _provider_name(attrs)

    if provider == BROKER_PROVIDER:
        return _broker(attrs.get("custom:idp_agency", ""))

    if provider == WORKFORCE_PROVIDER:
        groups = _parse_groups(attrs.get("custom:idp_groups"))
        role = next((g for g in groups if g in STAFF_ROLES), None)
        return _staff(role, attrs.get("custom:idp_region", ""))

    if provider is None and ALLOW_TEST_USERS:
        population = attrs.get("custom:t_population", "")
        if population == "broker":
            return _broker(attrs.get("custom:t_agency", ""))
        if population == "staff":
            return _staff(attrs.get("custom:t_role"), attrs.get("custom:t_region", ""))

    raise SignInRejected("Unrecognised identity provider or user type")


def handler(event, context):
    attrs = event["request"]["userAttributes"]
    try:
        claims = build_claims(attrs)
    except SignInRejected as exc:
        log.warning(json.dumps({"event": "sign_in_rejected", "reason": str(exc),
                                "trigger": event.get("triggerSource")}))
        raise

    event["response"]["claimsAndScopeOverrideDetails"] = {
        "accessTokenGeneration": {
            "claimsToAddOrOverride": claims,
            # Ensures non-OAuth sign-ins (test users) also carry the API scope.
            "scopesToAdd": [API_SCOPE],
        },
        "idTokenGeneration": {"claimsToAddOrOverride": claims},
    }
    return event
