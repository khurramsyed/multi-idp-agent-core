"""Mock Policy API — a stand-in for the insurer's existing policy administration system."""

import json
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException

from common.auth import broker_can_see, caller

_DATA = json.loads((Path(__file__).parent / "data" / "policies.json").read_text())
POLICIES = {p["policy_id"]: p for p in _DATA}

app = FastAPI(title="Mock Policy API", version="1.0.0")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/policies/{policy_id}")
def get_policy(policy_id: str, who: dict = Depends(caller)) -> dict:
    policy = POLICIES.get(policy_id)
    if policy is None or not broker_can_see(policy, who):
        raise HTTPException(status_code=404, detail="not found")
    return policy
