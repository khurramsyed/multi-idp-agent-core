"""Shared helpers for the test scripts: Terraform outputs and Cognito sign-in."""

import json
import pathlib
import subprocess
import sys

import boto3

ROOT = pathlib.Path(__file__).resolve().parent.parent


def tf_outputs() -> dict:
    raw = subprocess.check_output(
        ["terraform", f"-chdir={ROOT / 'infra'}", "output", "-json"], text=True
    )
    return {k: v["value"] for k, v in json.loads(raw).items()}


def sign_in(outputs: dict, username: str, password: str) -> str:
    """USER_PASSWORD_AUTH for admin-created test users. Returns the access token."""
    cognito = boto3.client("cognito-idp", region_name=outputs["region"])
    try:
        resp = cognito.initiate_auth(
            ClientId=outputs["app_client_id"],
            AuthFlow="USER_PASSWORD_AUTH",
            AuthParameters={"USERNAME": username, "PASSWORD": password},
        )
    except cognito.exceptions.NotAuthorizedException as exc:
        sys.exit(f"Sign-in failed for {username}: {exc}")
    except cognito.exceptions.UserLambdaValidationException as exc:
        sys.exit(f"Sign-in rejected by the pre token trigger for {username}: {exc}")
    return resp["AuthenticationResult"]["AccessToken"]
