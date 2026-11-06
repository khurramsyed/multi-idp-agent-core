import pytest
from fastapi.testclient import TestClient

from common import auth
from conftest import OTHER_KEY, PRIVATE_KEY, make_token


@pytest.fixture(autouse=True)
def _local_jwks(monkeypatch):
    monkeypatch.setattr(auth, "_signing_key", lambda token: PRIVATE_KEY.public_key())


@pytest.fixture
def claims_client():
    from claims_api.main import app
    return TestClient(app)


@pytest.fixture
def policy_client():
    from policy_api.main import app
    return TestClient(app)


def bearer(**claims):
    return {"Authorization": f"Bearer {make_token(**claims)}"}


def test_health_needs_no_token(claims_client, policy_client):
    assert claims_client.get("/health").status_code == 200
    assert policy_client.get("/health").status_code == 200


def test_missing_token_is_401(claims_client):
    assert claims_client.get("/claims/CLM-1001").status_code == 401


def test_wrong_signing_key_is_401(claims_client, monkeypatch):
    token = make_token(key=OTHER_KEY)
    resp = claims_client.get("/claims/CLM-1001", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 401


@pytest.mark.parametrize("override", [
    {"token_use": "id"},
    {"client_id": "someone-else"},
    {"iss": "https://evil.example.com"},
])
def test_wrong_token_shape_is_401(claims_client, override):
    assert claims_client.get("/claims/CLM-1001", headers=bearer(**override)).status_code == 401


def test_missing_scope_is_403(claims_client):
    assert claims_client.get("/claims/CLM-1001", headers=bearer(scope="openid")).status_code == 403


def test_unknown_population_is_403(claims_client):
    assert claims_client.get("/claims/CLM-1001", headers=bearer(population="admin")).status_code == 403


def test_broker_reads_own_agency(claims_client):
    resp = claims_client.get("/claims/CLM-1001", headers=bearer(population="broker", agency_id="AG-100"))
    assert resp.status_code == 200
    assert resp.json()["claim_id"] == "CLM-1001"


def test_broker_cannot_see_other_agency_and_gets_404(claims_client):
    resp = claims_client.get("/claims/CLM-1003", headers=bearer(population="broker", agency_id="AG-100"))
    assert resp.status_code == 404


def test_broker_with_empty_agency_sees_nothing(claims_client):
    resp = claims_client.get("/claims", headers=bearer(population="broker", agency_id=""))
    assert resp.json()["items"] == []


def test_broker_search_is_filtered(claims_client):
    resp = claims_client.get("/claims", headers=bearer(population="broker", agency_id="AG-200"))
    ids = {c["claim_id"] for c in resp.json()["items"]}
    assert ids == {"CLM-1003", "CLM-1005", "CLM-1006"}


def test_staff_search_is_not_filtered_by_api(claims_client):
    resp = claims_client.get("/claims?status=open", headers=bearer())
    assert {c["status"] for c in resp.json()["items"]} == {"OPEN"}
    assert len(resp.json()["items"]) == 3


def test_policy_api_applies_same_backstop(policy_client):
    ok = policy_client.get("/policies/POL-2001", headers=bearer(population="broker", agency_id="AG-100"))
    hidden = policy_client.get("/policies/POL-2002", headers=bearer(population="broker", agency_id="AG-100"))
    assert ok.status_code == 200 and hidden.status_code == 404
