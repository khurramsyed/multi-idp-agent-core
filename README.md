# One Agent, Two Front Doors — reference implementation

A claims-assistant AI agent on **Amazon Bedrock AgentCore** that two very different groups of users share safely: insurer **staff** (claims adjusters, on a workforce identity provider) and external **brokers** (on a separate customer identity provider). Every tool call runs with the end user's own identity, authorization is decided by **Amazon Verified Permissions** (Cedar) at the tool boundary, never by the model, and every record the agent reads is logged against the human who asked.

This repository accompanies the article *One Agent, Two Front Doors*. It is a sanitised reference implementation for learning and experimentation, not a production system. The claims and policy systems are mocks with fictional data.

![Architecture](docs/architecture.png)

The editable source is `docs/architecture.drawio`; open it in [diagrams.net](https://app.diagrams.net).

## What gets deployed

| Layer | AWS services | Folder |
|---|---|---|
| Identity broker | Amazon Cognito user pool (Essentials), pre token generation trigger (Lambda) | `infra/cognito.tf`, `lambdas/pre_token` |
| Agent | Amazon Bedrock AgentCore Runtime (container, arm64), Strands Agents | `agent/` |
| Tools | AgentCore Gateway (MCP, custom JWT authorizer), request interceptor (Lambda), tool adapters (Lambda) | `infra/agentcore.tf`, `lambdas/` |
| Authorization | Amazon Verified Permissions with Cedar policies | `policies/`, `infra/verified_permissions.tf` |
| Systems of record | Mock Claims API and mock Policy API on Amazon ECS on AWS Fargate behind an internal ALB | `services/`, `infra/ecs.tf` |
| Audit | CloudWatch Logs metric filters, alarm, saved Logs Insights queries | `infra/observability.tf` |

## How one tool call flows

1. The user signs in. Cognito federates the workforce IdP and the broker IdP (or, for testing, admin-created test users).
2. The **pre token generation trigger** normalises every access token to four claims: `population`, `agency_id`, `role`, `region`. Sign-in fails if a required value is missing.
3. The client invokes the agent on **AgentCore Runtime** with the Cognito access token. The Runtime validates it and forwards the `Authorization` header to the agent code (`request_header_allowlist`).
4. The agent calls **AgentCore Gateway** over MCP with the *same* user token. The Gateway validates it again.
5. The **request interceptor** re-validates the token, removes any client- or model-supplied `_caller_token` argument, and injects the verified token into that reserved argument.
6. The **tool Lambda** fetches the record from the mock API (forwarding the user's token), asks **Verified Permissions** `IsAuthorizedWithToken` / `BatchIsAuthorizedWithToken`, and releases a field projection only on `ALLOW`.
7. The **mock APIs on Fargate** validate the token independently and never return another agency's record to a broker token (backstop).
8. Every decision is logged as structured JSON with the user's `sub` and `username`, the tool, the record ID and the result.

## Prerequisites

- An AWS account and credentials with permission to create the resources above.
- A Region where Amazon Bedrock AgentCore is available. The default is `eu-west-1`.
- **Model access** in Amazon Bedrock for the model in `model_id` (default: the EU cross-Region inference profile for Claude Sonnet 4.5). Any tool-use-capable model or inference profile works.
- Terraform 1.6 or later, AWS CLI v2, Docker with `buildx` (images are built for `linux/arm64`), Python 3.12 and [uv](https://docs.astral.sh/uv/).
- On an x86 machine, enable arm64 emulation for Docker once: `docker run --privileged --rm tonistiigi/binfmt --install arm64`. Apple silicon and other arm64 machines need nothing extra.

## Deploy

```bash
git clone <your-repo-url> claims-assist-agentcore && cd claims-assist-agentcore
cp infra/terraform.tfvars.example infra/terraform.tfvars   # adjust region, project, model_id

export AWS_REGION=eu-west-1        # must match region in terraform.tfvars
export PROJECT=claims-assist       # must match project in terraform.tfvars
scripts/deploy.sh                  # add -auto-approve to skip the final confirmation
```

`deploy.sh` builds the Lambda packages, creates the ECR repositories, builds and pushes the three arm64 images (Claims API, Policy API, agent), then applies the full stack. A first deploy takes roughly 10–15 minutes, mostly NAT gateway, ALB and AgentCore resources. [How deployment works](#how-deployment-works) explains each step and how every component reaches AWS.

To redeploy after code changes, run `scripts/deploy.sh` again. Image tags come from the Git commit, so commit your changes first (ECR tags are immutable; the script adds a timestamp if the tree is dirty).

## How deployment works

Everything is deployed by one Terraform stack in `infra/`, driven by `scripts/deploy.sh` (locally) or the `deploy` workflow (GitHub Actions, which calls the same script). There is no separate release step for individual components: a deploy builds the artifacts, then Terraform wires them into AWS.

### Order of operations

`scripts/deploy.sh` runs these steps in order:

| Step | What happens | Why this order |
|---|---|---|
| 1. Pick an image tag | The short Git commit SHA (plus a timestamp if the working tree is dirty), exported as `TF_VAR_image_tag`. Override with `IMAGE_TAG`. | ECR tags are immutable, so every distinct build needs a distinct tag. |
| 2. `build_lambdas.sh` | Copies each Lambda's source into `build/lambdas/<name>/`. The interceptor's third-party dependencies (`PyJWT`) are installed there from `uv.lock` as arm64 wheels. | Terraform zips these folders in the next steps, so they must exist first. |
| 3. `terraform init -upgrade` | Initialises providers. | |
| 4. `terraform apply -target=aws_ecr_repository.this` | Creates only the three ECR repositories (`claims-api`, `policy-api`, `agent`). | The images must be in ECR before ECS and AgentCore Runtime are created, and the repositories must exist before an image can be pushed. This is the one targeted apply. |
| 5. `build_and_push.sh` | Builds the three `linux/arm64` images with `docker buildx` and pushes them. Skips any image whose tag is already in ECR. | The task definitions and the Runtime reference these images by tag. |
| 6. `terraform apply` | Creates or updates everything else. | All inputs now exist. |

A first deploy takes about 10-15 minutes; later deploys only change what differs.

### How each part is deployed

| Part | Artifact | How it reaches AWS |
|---|---|---|
| **Mock Claims API and Policy API** | One image (`services/Dockerfile`), built twice with `SERVICE=claims_api` and `SERVICE=policy_api` | Pushed to ECR. `infra/ecs.tf` creates the ECS task definitions that reference `<repo>:<image_tag>` and the Fargate services behind an internal ALB. A new image tag changes the task definition, which rolls the service. |
| **Agent** | Container image (`agent/Dockerfile`, arm64) | Pushed to ECR. `aws_bedrockagentcore_agent_runtime` in `infra/agentcore.tf` points at `<repo>:<image_tag>`. A new tag updates the Runtime to the new image. |
| **Pre token generation, interceptor and tools Lambdas** | Zip packages built from `build/lambdas/` | Terraform's `archive_file` zips each folder and `aws_lambda_function` uploads it directly (no S3 or ECR). `source_code_hash` makes a code change trigger an update. The tools Lambda runs inside the VPC to reach the internal ALB. |
| **Cedar policies and schema** | `policies/*.cedar` and `policies/schema.json` | Read by Terraform with `file()` / `fileset()`. They are created as Verified Permissions policies in the policy store. Adding a `.cedar` file adds a policy on the next apply. |
| **AgentCore Gateway and its tool target** | No build artifact | Defined in `infra/agentcore.tf`. The target is the tools Lambda, with the tool schema inline in Terraform. The interceptor is attached as the gateway's request interceptor. |
| **Cognito, VPC, ALB, IAM, observability** | No build artifact | Plain Terraform resources in `infra/cognito.tf`, `network.tf`, `ecs.tf`, `observability.tf`. |

### Changing one component

You always rerun the whole `deploy.sh`; Terraform only changes what differs.

- **Lambda code**: edit, rebuild (the script does it), and Terraform updates only the changed function.
- **Service or agent code**: commit, then deploy. The new SHA gives a new image tag, so ECS or the Runtime picks it up. With uncommitted changes the script adds a timestamp, so you still get a fresh tag.
- **Cedar policies**: edit the `.cedar` files and deploy. No image or Lambda rebuild is involved.
- **Dependencies**: edit `pyproject.toml`, run `uv lock`, commit, then deploy (see [Python dependencies](#python-dependencies)).

### Terraform state

Locally, state is a file in `infra/` (gitignored). In GitHub Actions it is in the S3 bucket created by `bootstrap/`; `scripts/ci_remote_state.sh` writes `infra/backend_override.tf` and the `TF_CLI_ARGS_init` settings for that. The two are independent: a stack deployed locally is invisible to the workflows, so destroy one before deploying the other.

### Deploying from GitHub Actions

`deploy.yml` runs the tests (`ci.yml`), assumes the deploy role through OIDC, sets up QEMU and Buildx so the x86 runner can build arm64 images, switches Terraform to the remote state, then runs the same `scripts/deploy.sh -auto-approve`. See [CI/CD with GitHub Actions](#cicd-with-github-actions) for the one-off setup.

## Try it

Create the five test users (they exist only because `enable_test_users = true`):

```bash
uv sync   # creates .venv from uv.lock (includes boto3 for the scripts)
source .venv/bin/activate
export TEST_USER_PASSWORD='Choose-A-Strong-Passw0rd!'
scripts/create_test_users.sh
```

### 1. Prove the authorization chain without a model

`call_tool.py` signs in as a user and calls Gateway tools directly over MCP:

```bash
python scripts/call_tool.py --user broker.ag100 list
python scripts/call_tool.py --user broker.ag100 get_claim claim_id=CLM-1001   # own agency: returned
python scripts/call_tool.py --user broker.ag100 get_claim claim_id=CLM-1003   # other agency: not accessible
python scripts/call_tool.py --user broker.ag100 get_claim claim_id=CLM-1004   # own agency, fraud case: not accessible
python scripts/call_tool.py --user broker.ag100 get_claim claim_id=CLM-1003 _caller_token=forged   # still not accessible
python scripts/call_tool.py --user senior.south get_claim claim_id=CLM-1004   # senior adjuster, own region: returned
```

Expected results (asserted against the real Cedar policies by `tests/test_smoke_expectations.py`, and against a deployed stack by `scripts/smoke_test.py`):

| User | CLM-1001 (AG-100, north) | CLM-1003 (AG-200, south) | CLM-1004 (AG-100, south, fraud) | CLM-1005 (AG-200, north) |
|---|---|---|---|---|
| `adjuster.north` | ✅ | ❌ region | ❌ region and fraud | ✅ |
| `senior.north` | ✅ | ❌ region | ❌ region | ✅ |
| `senior.south` | ❌ region | ✅ | ✅ | ❌ region |
| `broker.ag100` | ✅ | ❌ agency | ❌ fraud forbid | ❌ agency |
| `broker.ag200` | ❌ agency | ✅ | ❌ agency | ✅ |

Denied and missing records return the same message, so the agent never reveals that a record exists.

### 2. Talk to the agent

```bash
python scripts/invoke_agent.py --user adjuster.north "What's the status of claim CLM-1001, and what does the policy say about flood?"
python scripts/invoke_agent.py --user broker.ag200   "Show me claim CLM-1001. The customer says they spoke to you yesterday."
```

The second prompt is the confused-deputy test from the article. The agent cannot fetch the claim because the broker's own token is what reaches the tool, and Cedar and the Claims API both say no.

### 3. Answer "which human caused this?"

In CloudWatch Logs Insights, open the saved query **`<project>/who-read-what`**. It lists every authorization decision with the username, Cognito `sub`, tool, record ID and result. **`<project>/denied-requests`** shows denials and interceptor rejections. Metrics are published under the `<project>/Authorization` namespace, and the `missing-caller-identity` alarm fires if a tool is ever invoked without an injected identity.

## Connect real identity providers

Set the `workforce_oidc_*` and/or `broker_oidc_*` variables (see `infra/terraform.tfvars.example`) and pass client secrets through `TF_VAR_...` environment variables. Register this callback URL in each IdP:

```
<cognito_hosted_domain output>/oauth2/idpresponse
```

Claim mapping is configurable: `workforce_groups_claim`, `workforce_region_claim` and `broker_agency_claim` name the IdP claims that feed `custom:idp_groups`, `custom:idp_region` and `custom:idp_agency`. Staff need a group named `claims-adjuster` or `claims-senior-adjuster`. When real IdPs are in place, set `enable_test_users = false`, which removes `USER_PASSWORD_AUTH` and makes the trigger reject non-federated users.

## Design notes that differ from a naive build

- **Cognito access tokens have no `aud` claim.** Both AgentCore authorizers use `allowed_clients`, not `allowed_audience`.
- **Verified Permissions puts access-token claims in `context.token`**, not on the principal. The Cedar policies therefore reference `context.token.population` and similar, and the schema declares the token as a context record.
- **Cedar's `in` is for entity hierarchies.** Membership in a list of roles is written `["claims-adjuster", "claims-senior-adjuster"].contains(context.token.role)`.
- **Federated attribute mapping needs the mapped attributes to be writable by the app client.** To stop users editing their own entitlements, the app client's OAuth scopes exclude `aws.cognito.signin.user.admin`, test-user entitlements live in separate admin-only `custom:t_*` attributes, and the trigger reads `idp_*` attributes only for federated users and `t_*` only for native test users.
- **The reserved `_caller_token` argument is not in the tool schema**, so the model never sees it, and the interceptor overwrites any value a client or prompt injection supplies.

## Costs

This stack runs billable resources continuously: a NAT gateway, an internal Application Load Balancer and two Fargate tasks. Cognito Essentials is billed per monthly active user, and AgentCore Runtime, Gateway, Lambda, Verified Permissions and Bedrock model calls are billed per use. Use the AWS Pricing Calculator for your Region, filter Cost Explorer by the `Project` tag (applied to every resource) and the `Component` tag, and **destroy the stack when you are done**.

## Tear down

Run this from the same machine and folder you deployed from (it needs the local Terraform state):

```bash
export AWS_REGION=eu-west-1        # same values you deployed with
export PROJECT=claims-assist
scripts/destroy.sh                 # add -auto-approve to skip the confirmation
```

`destroy.sh` does four things:

1. Rebuilds the Lambda packages, because Terraform reads them even when destroying.
2. Runs `terraform destroy` with a placeholder `image_tag`, which has no default.
3. Deletes the CloudWatch log group that AgentCore Runtime creates for itself on first use. Terraform does not manage that group and it never expires.
4. Runs `scripts/check_leftovers.sh`, which prints `Nothing left` when no resource from this stack remains in the Region.

ECR repositories are created with `force_delete`, and the user pool and policy store have deletion protection off, so `terraform destroy` removes them along with their contents.

If destroy stops with a `DependencyViolation` on a subnet or security group, wait 10–40 minutes for AWS to release the tools Lambda's VPC network interfaces, then run `scripts/destroy.sh` again.

After teardown nothing in this stack keeps billing. Charges already incurred (hours the NAT gateway, ALB and Fargate tasks ran, model tokens used) still appear on that month's bill. Cost Explorer can take up to 24 hours to show the final figures.

## CI/CD with GitHub Actions

Three workflows live in `.github/workflows/`:

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Every push and pull request | Unit and Cedar policy tests, shellcheck, `terraform fmt` and `validate`. No AWS access. |
| `deploy.yml` | Manual (Actions tab, **Run workflow**) | Runs CI, then builds and pushes the arm64 images, applies Terraform, creates the test users and runs `scripts/smoke_test.py` against the deployed gateway. |
| `destroy.yml` | Manual, and you must type the project name | Runs `scripts/destroy.sh`, which deletes everything, removes the AgentCore log groups and fails if `check_leftovers.sh` finds anything. |

Deploy is manual on purpose: every deploy starts resources that bill by the hour. `deploy.yml` has a commented-out `push` trigger if you want continuous deployment, and `destroy.yml` has a commented-out nightly schedule as a safety net.

GitHub authenticates to AWS with OIDC, so no access keys are stored in GitHub. Terraform state lives in S3, because CI runners keep nothing between runs; local runs are unaffected and keep local state.

### One-off setup

1. **Bootstrap AWS** (locally, with admin credentials). This creates the state bucket, the GitHub OIDC provider and a deploy role that only jobs in this repository's `aws-dev` environment can assume:

   ```bash
   terraform -chdir=bootstrap init
   terraform -chdir=bootstrap apply -var github_owner=<owner> -var github_repo=<repo>
   ```

   If the account already has the GitHub OIDC provider, add `-var create_oidc_provider=false`. If your GitHub plan does not offer deployment environments for this repository, add `-var 'oidc_subject=repo:<owner>/<repo>:ref:refs/heads/main'` and remove the `environment:` lines from the two workflows.

2. **Create the `aws-dev` environment** under the repository's **Settings → Environments**. Add a required reviewer if your plan supports it, so every deploy and destroy waits for approval.

3. **Add environment variables and a secret** to `aws-dev`:

   | Name | Type | Value |
   |---|---|---|
   | `AWS_DEPLOY_ROLE_ARN` | Variable | `AWS_DEPLOY_ROLE_ARN` bootstrap output |
   | `TF_STATE_BUCKET` | Variable | `TF_STATE_BUCKET` bootstrap output |
   | `AWS_REGION` | Variable (optional) | Defaults to `eu-west-1` |
   | `PROJECT` | Variable (optional) | Defaults to `claims-assist` |
   | `MODEL_ID` | Variable (optional) | Defaults to the Terraform default |
   | `ENABLE_TEST_USERS` | Variable (optional) | `false` skips test users and the smoke test |
   | `TEST_USER_PASSWORD` | Secret | 12+ characters with upper, lower, digit and symbol |

4. **Enable model access** in the Bedrock console for the Region, as for a local deploy.

If you have already deployed locally, run `scripts/destroy.sh` first. The workflows use the S3 state, so they cannot see a stack recorded in your local state, and a second deploy would collide on resource names.

### Permissions

The deploy role has `PowerUserAccess`, plus IAM rights limited to roles whose names start with the project prefix, and it cannot modify itself. Use a sandbox or dedicated account for this stack.

### Removing the CI/CD setup

After running the destroy workflow, remove the bootstrap with `terraform -chdir=bootstrap destroy` (same `-var` flags). The state bucket is created with `force_destroy`, so this removes it and its contents.

## Python dependencies

Dependencies are managed with [uv](https://docs.astral.sh/uv/). They are declared in `pyproject.toml` as one dependency group per deployable (`services`, `agent`, `interceptor`, `scripts`, plus `dev` for tests) and locked in `uv.lock`, which is committed.

- Add or change a dependency: edit `pyproject.toml` (or `uv add --group <group> <pkg>`), then run `uv lock`.
- The Docker images and the interceptor Lambda install only their own group from the lockfile (`uv sync --frozen --only-group ...`), so the build context for the images is the repo root.
- The `agent` group conflicts with `dev`/`services` (newer `fastapi`/`uvicorn` via `bedrock-agentcore`), so `pyproject.toml` declares them as `conflicts` and uv resolves them independently.

## Run the tests locally

```bash
uv sync
uv run pytest -q
```

The tests cover the mock APIs' token validation and backstop, the pre token trigger's claim normalisation and fail-closed rules, the interceptor's injection and rejection paths, and the tool adapters end to end. The tool tests evaluate the **real Cedar policies against the real schema** with `cedarpy`, so a policy change that breaks a business rule fails CI.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Sign-in fails with a pre token generation error | The user's IdP did not assert an agency, claims role or region. This is deliberate. Check the trigger's logs. |
| Every tool returns `Caller identity unavailable.` | The reserved argument did not reach the Lambda. Confirm `pass_request_headers = true` on the interceptor and check the interceptor's logs. If your Gateway version drops undeclared arguments, add `_caller_token` to each tool's `input_schema` (the interceptor still overwrites it). |
| Agent returns `Caller identity unavailable.` | The Runtime did not forward the header. Confirm `request_header_allowlist = ["Authorization"]`. |
| Agent errors with `AccessDeniedException` from Bedrock | Model access is not enabled for `model_id` in this Region, or the inference profile is not available here. |
| ECS tasks fail to start | Images were not pushed for this `image_tag`, or were built for the wrong architecture (they must be `linux/arm64`). |
| `terraform apply` complains about unknown AgentCore arguments | Upgrade the AWS provider. AgentCore resources need `hashicorp/aws` 6.38 or later. |

## Repository layout

```
agent/                 Strands agent for AgentCore Runtime (Dockerfile, arm64)
docs/                  Architecture diagram (draw.io)
infra/                 Terraform: network, ECR, ECS, Cognito, Lambdas, Verified Permissions, AgentCore, observability
lambdas/pre_token/     Cognito pre token generation trigger (V2)
lambdas/interceptor/   AgentCore Gateway request interceptor
lambdas/tools/         Tool adapters: get_claim, search_claims, get_policy
policies/              Cedar schema and policies
scripts/               Deploy, destroy, leftover check, smoke test, CI helpers, build, test users, test clients
bootstrap/             One-off Terraform for GitHub Actions: state bucket, OIDC provider, deploy role
.github/workflows/     CI, deploy and destroy workflows
services/              Mock Claims and Policy APIs (FastAPI) for ECS Fargate
tests/                 Unit tests, including Cedar policy tests
```

## Licence

Add the licence of your choice before publishing (for example MIT-0, which AWS samples commonly use).
