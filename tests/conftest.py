import os
import sys
import time
import uuid
from pathlib import Path

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "services"))

ISSUER = "https://cognito-idp.eu-west-1.amazonaws.com/eu-west-1_TEST"
CLIENT_ID = "testclient123"

os.environ.update({
    "COGNITO_ISSUER": ISSUER,
    "APP_CLIENT_ID": CLIENT_ID,
    "REQUIRED_SCOPE": "claims-api/claims.read",
    "POLICY_STORE_ID": "ps-test",
    "API_BASE_URL": "http://api.internal",
    "AWS_DEFAULT_REGION": "eu-west-1",
})

PRIVATE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def make_token(key=PRIVATE_KEY, **overrides) -> str:
    now = int(time.time())
    claims = {
        "sub": str(uuid.uuid4()),
        "iss": ISSUER,
        "client_id": CLIENT_ID,
        "token_use": "access",
        "scope": "openid claims-api/claims.read",
        "username": "tester",
        "iat": now,
        "exp": now + 900,
        "population": "staff",
        "role": "claims-adjuster",
        "region": "north",
        "agency_id": "",
    }
    claims.update(overrides)
    claims = {k: v for k, v in claims.items() if v is not None}
    return jwt.encode(claims, key, algorithm="RS256")


@pytest.fixture
def public_key():
    return PRIVATE_KEY.public_key()
