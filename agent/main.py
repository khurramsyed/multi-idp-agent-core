"""Claims assistant agent hosted on Amazon Bedrock AgentCore Runtime.

The agent never holds its own credentials to the claims systems. On every
invocation it takes the end user's Cognito access token (validated by the
Runtime's inbound JWT authorizer and forwarded via the header allowlist) and
presents that same token to AgentCore Gateway when it calls tools.
"""

import logging
import os

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("claims-agent")

GATEWAY_URL = os.environ["GATEWAY_URL"]
MODEL_ID = os.environ["MODEL_ID"]
REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION"))

SYSTEM_PROMPT = """You are a claims assistant for a commercial insurer. You help two kinds of users:
claims adjusters (insurer employees) and independent insurance brokers.

Rules:
- Answer only from what your tools return. Never guess claim or policy details.
- If a tool says a record is "not found or not accessible", tell the user exactly that.
  Never speculate about whether the record exists or who it belongs to.
- You cannot change records. If asked to, explain that you can only look things up.
- Claim IDs look like CLM-1234 and policy IDs look like POL-1234.
- Be concise and factual. Use plain language a broker's customer would understand."""

app = BedrockAgentCoreApp()
model = BedrockModel(model_id=MODEL_ID, region_name=REGION, temperature=0.2)


def _gateway_mcp_url() -> str:
    return GATEWAY_URL if GATEWAY_URL.rstrip("/").endswith("/mcp") else GATEWAY_URL.rstrip("/") + "/mcp"


def _bearer_token(context) -> str | None:
    headers = getattr(context, "request_headers", None) or {}
    for name, value in headers.items():
        if name.lower() == "authorization" and value.startswith("Bearer "):
            return value[len("Bearer "):]
    return None


@app.entrypoint
def invoke(payload, context):
    prompt = (payload or {}).get("prompt", "").strip()
    if not prompt:
        return {"error": "Send a JSON body like {\"prompt\": \"What is the status of CLM-1001?\"}"}

    token = _bearer_token(context)
    if not token:
        # Runtime validated the token but did not forward it: check request_header_allowlist.
        log.error("Authorization header not forwarded to the agent")
        return {"error": "Caller identity unavailable."}

    # A fresh MCP client per invocation, carrying this user's token and nobody else's.
    gateway = MCPClient(url=_gateway_mcp_url(), headers={"Authorization": f"Bearer {token}"})
    try:
        with gateway:
            tools = gateway.list_tools_sync()
            agent = Agent(model=model, tools=tools, system_prompt=SYSTEM_PROMPT, callback_handler=None)
            result = agent(prompt)
    except Exception:  # noqa: BLE001 — never leak internals to the caller
        log.exception("Agent invocation failed")
        return {"error": "The assistant could not complete this request. Please try again."}

    return {"result": str(result), "session_id": getattr(context, "session_id", None)}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
