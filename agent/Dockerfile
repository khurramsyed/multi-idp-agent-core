# AgentCore Runtime requires linux/arm64 images. Build context is the repo root (for uv.lock).
#   docker buildx build --platform linux/arm64 -f agent/Dockerfile .
FROM public.ecr.aws/docker/library/python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH="/opt/venv/bin:$PATH"

COPY --from=ghcr.io/astral-sh/uv:0.11 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --only-group agent --no-cache

COPY agent/main.py .

RUN useradd --system --uid 10001 agent
USER 10001

EXPOSE 8080
CMD ["python", "main.py"]
