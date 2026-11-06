"""AgentCore Gateway REQUEST interceptor.

The gateway has already validated the caller's bearer token. This function:
  1. re-validates it (defence in depth),
  2. strips any client- or model-supplied value from the reserved argument,
  3. injects the verified token into the reserved argument of tools/call,
     where the Lambda tool target can read it.

Everything that is not a tools/call passes through unchanged.
"""

import json
import logging
import os

import jwt
from jwt import PyJWKClient

log = logging.getLogger()
log.setLevel(logging.INFO)

ISSUER = os.environ["COGNITO_ISSUER"]
CLIENT_ID = os.environ["APP_CLIENT_ID"]
RESERVED_ARG = os.environ.get("RESERVED_ARG", "_caller_token")

_jwks = PyJWKClient(f"{ISSUER}/.well-known/jwks.json", cache_keys=True, lifespan=3600)


class TokenRejected(Exception):
    pass


def verify(token: str) -> dict:
    try:
        key = _jwks.get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, key, algorithms=["RS256"], issuer=ISSUER,
                            options={"verify_aud": False, "require": ["exp", "sub"]})
    except jwt.PyJWTError as exc:
        raise TokenRejected(str(exc)) from exc
    if claims.get("token_use") != "access" or claims.get("client_id") != CLIENT_ID:
        raise TokenRejected("unexpected token type or client")
    return claims


def _bearer(headers: dict) -> str | None:
    for name, value in (headers or {}).items():
        if name.lower() == "authorization" and isinstance(value, str) and value.startswith("Bearer "):
            return value[len("Bearer "):]
    return None


def _pass(body: dict) -> dict:
    return {"interceptorOutputVersion": "1.0",
            "mcp": {"transformedGatewayRequest": {"body": body}}}


def _deny(body: dict, status: int, message: str) -> dict:
    return {
        "interceptorOutputVersion": "1.0",
        "mcp": {
            "transformedGatewayResponse": {
                "statusCode": status,
                "body": {"jsonrpc": "2.0", "id": body.get("id"),
                         "error": {"code": -32001, "message": message}},
            }
        },
    }


def handler(event, context):
    request = event["mcp"]["gatewayRequest"]
    body = request.get("body") or {}
    if isinstance(body, str):
        body = json.loads(body)

    if body.get("method") != "tools/call":
        return _pass(body)

    token = _bearer(request.get("headers"))
    if not token:
        # Happens if passRequestHeaders is off: fail closed, never call the tool.
        log.error(json.dumps({"event": "interceptor_denied", "reason": "no bearer token"}))
        return _deny(body, 401, "Caller identity unavailable.")

    try:
        claims = verify(token)
    except TokenRejected as exc:
        log.warning(json.dumps({"event": "interceptor_denied", "reason": str(exc)}))
        return _deny(body, 401, "Caller identity rejected.")

    params = body.setdefault("params", {})
    args = params.get("arguments") or {}
    args.pop(RESERVED_ARG, None)  # never trust a model- or client-supplied value
    args[RESERVED_ARG] = token
    params["arguments"] = args

    log.info(json.dumps({"event": "identity_injected", "tool": params.get("name"),
                         "sub": claims.get("sub"), "population": claims.get("population")}))
    return _pass(body)
