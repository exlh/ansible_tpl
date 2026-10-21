FROM python:3.14.8-slim

ENV TZ="Europe/Moscow" \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

RUN apt-get update && apt-get install -y --no-install-recommends \
    rsync \
    openssh-client \
    sshpass \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /uvx /bin/

WORKDIR /root/ansible

COPY ./pyproject.toml ./uv.lock ./entrypoint.sh ./requirements.yml ./

RUN uv run ansible-galaxy collection install -r requirements.yml \
    && chmod a+x ./entrypoint.sh \
    && uv sync --frozen

ENTRYPOINT ["/root/ansible/entrypoint.sh"]
CMD ["uv", "run", "ansible-playbook", "--help"]
