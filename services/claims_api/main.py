"""Mock Claims API — a stand-in for the insurer's existing claims system of record."""

import json
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query

from common.auth import broker_can_see, caller

_DATA = json.loads((Path(__file__).parent / "data" / "claims.json").read_text())
CLAIMS = {c["claim_id"]: c for c in _DATA}
MAX_RESULTS = 50

app = FastAPI(title="Mock Claims API", version="1.0.0")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/claims/{claim_id}")
def get_claim(claim_id: str, who: dict = Depends(caller)) -> dict:
    claim = CLAIMS.get(claim_id)
    # Not found and not visible look identical, so existence never leaks.
    if claim is None or not broker_can_see(claim, who):
        raise HTTPException(status_code=404, detail="not found")
    return claim


@app.get("/claims")
def search_claims(
    policy_id: str | None = Query(default=None, max_length=32),
    status: str | None = Query(default=None, max_length=32),
    who: dict = Depends(caller),
) -> dict:
    wanted_status = status.upper() if status else None
    items = [
        c
        for c in CLAIMS.values()
        if broker_can_see(c, who)
        and (policy_id is None or c["policy_id"] == policy_id)
        and (wanted_status is None or c["status"] == wanted_status)
    ]
    return {"items": items[:MAX_RESULTS]}
