import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


def load(monkeypatch, allow_test_users="true"):
    monkeypatch.setenv("ALLOW_TEST_USERS", allow_test_users)
    spec = importlib.util.spec_from_file_location("pre_token", ROOT / "lambdas/pre_token/handler.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def event(attrs):
    return {"triggerSource": "TokenGeneration_Authentication",
            "request": {"userAttributes": attrs}, "response": {}}


def federated(provider):
    return json.dumps([{"providerName": provider, "providerType": "OIDC", "userId": "abc"}])


def test_workforce_user_with_json_groups(monkeypatch):
    m = load(monkeypatch)
    out = m.handler(event({
        "identities": federated("Workforce"),
        "custom:idp_groups": '["all-staff", "claims-senior-adjuster"]',
        "custom:idp_region": "North",
    }), None)
    access = out["response"]["claimsAndScopeOverrideDetails"]["accessTokenGeneration"]
    assert access["claimsToAddOrOverride"] == {
        "population": "staff", "agency_id": "", "role": "claims-senior-adjuster", "region": "north"}
    assert access["scopesToAdd"] == ["claims-api/claims.read"]


def test_workforce_user_with_comma_groups(monkeypatch):
    m = load(monkeypatch)
    claims = m.build_claims({"identities": federated("Workforce"),
                             "custom:idp_groups": "[finance, claims-adjuster]",
                             "custom:idp_region": "south"})
    assert claims["role"] == "claims-adjuster"


def test_broker_user(monkeypatch):
    m = load(monkeypatch)
    claims = m.build_claims({"identities": federated("Brokers"), "custom:idp_agency": "AG-100"})
    assert claims == {"population": "broker", "agency_id": "AG-100", "role": "broker", "region": ""}


@pytest.mark.parametrize("attrs", [
    {"identities": federated("Brokers")},                                            # no agency
    {"identities": federated("Workforce"), "custom:idp_groups": '["finance"]',
     "custom:idp_region": "north"},                                                  # no claims role
    {"identities": federated("Workforce"), "custom:idp_groups": '["claims-adjuster"]'},  # no region
    {"identities": federated("SomeOtherIdP")},                                       # unknown IdP
])
def test_incomplete_identities_fail_sign_in(monkeypatch, attrs):
    m = load(monkeypatch)
    with pytest.raises(m.SignInRejected):
        m.build_claims(attrs)


def test_native_test_user_allowed_only_when_enabled(monkeypatch):
    attrs = {"custom:t_population": "broker", "custom:t_agency": "AG-200"}
    assert load(monkeypatch, "true").build_claims(attrs)["agency_id"] == "AG-200"
    m = load(monkeypatch, "false")
    with pytest.raises(m.SignInRejected):
        m.build_claims(attrs)


def test_federated_user_cannot_use_test_attributes(monkeypatch):
    m = load(monkeypatch)
    claims = m.build_claims({"identities": federated("Brokers"), "custom:idp_agency": "AG-100",
                             "custom:t_agency": "AG-200"})
    assert claims["agency_id"] == "AG-100"


def test_native_user_cannot_use_idp_attributes(monkeypatch):
    m = load(monkeypatch)
    with pytest.raises(m.SignInRejected):
        m.build_claims({"custom:idp_agency": "AG-100"})
