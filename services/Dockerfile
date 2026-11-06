# One image definition for both mock APIs. Build context is the repo root (for uv.lock).
#   docker buildx build --platform linux/arm64 --build-arg SERVICE=claims_api -f services/Dockerfile .
#   docker buildx build --platform linux/arm64 --build-arg SERVICE=policy_api -f services/Dockerfile .
FROM public.ecr.aws/docker/library/python:3.12-slim

ARG SERVICE
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv UV_COMPILE_BYTECODE=0 \
    PATH="/opt/venv/bin:$PATH"

COPY --from=ghcr.io/astral-sh/uv:0.11 /uv /usr/local/bin/uv

WORKDIR /srv
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --only-group services --no-cache

COPY services/common ./common
COPY services/${SERVICE} ./app

RUN useradd --system --uid 10001 api
USER 10001

EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
