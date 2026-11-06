"""Bearer-token validation shared by the mock Claims and Policy APIs.

The APIs never trust the caller because it sits inside the VPC. Every request
must carry the end user's Cognito access token, and each service validates it
independently: signature, issuer, token type, app client and scope.
"""

import os
from functools import lru_cache

import jwt
from fastapi import Header, HTTPException
from jwt import PyJWKClient

POPULATIONS = {"staff", "broker"}


def _issuer() -> str:
    return os.environ["COGNITO_ISSUER"]


def _client_id() -> str:
    return os.environ["APP_CLIENT_ID"]


def _required_scope() -> str:
    return os.environ.get("REQUIRED_SCOPE", "claims-api/claims.read")


@lru_cache(maxsize=1)
def _jwks_client() -> PyJWKClient:
    # Keys are cached in memory for the life of the task.
    return PyJWKClient(f"{_issuer()}/.well-known/jwks.json", cache_keys=True, lifespan=3600)


def _signing_key(token: str):
    return _jwks_client().get_signing_key_from_jwt(token).key


def verify_access_token(token: str) -> dict:
    try:
        claims = jwt.decode(
            token,
            _signing_key(token),
            algorithms=["RS256"],
            issuer=_issuer(),
            # Cognito access tokens have no "aud"; the app client is in "client_id".
            options={"verify_aud": False, "require": ["exp", "iat", "sub"]},
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail="invalid token") from exc

    if claims.get("token_use") != "access" or claims.get("client_id") != _client_id():
        raise HTTPException(status_code=401, detail="unexpected token")
    if _required_scope() not in claims.get("scope", "").split():
        raise HTTPException(status_code=403, detail="missing scope")
    if claims.get("population") not in POPULATIONS:
        raise HTTPException(status_code=403, detail="unknown population")
    return claims


def caller(authorization: str | None = Header(default=None)) -> dict:
    """FastAPI dependency returning the validated token claims of the end user."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    return verify_access_token(authorization[len("Bearer "):])


def broker_can_see(record: dict, who: dict) -> bool:
    """Coarse backstop: a broker token only ever reaches its own agency's records.

    Staff are not filtered here. Their fine-grained rules (region, role, fraud
    investigations) are decided by Amazon Verified Permissions in the tool layer.
    """
    if who["population"] != "broker":
        return True
    agency = who.get("agency_id", "")
    return bool(agency) and record.get("agency_id") == agency
