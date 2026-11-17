"""Database wiring.

Credentials are never in the image or in the environment as literals: External
Secrets Operator projects the Secrets Manager value into a Kubernetes secret,
and the pod reads it from a file. Rotation therefore means a secret refresh and
a pod restart, not a redeploy.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import quote_plus

from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from .telemetry import get_logger

log = get_logger(component="db")


def database_url_from_secret(
    path: str = "/var/run/secrets/db/credentials.json",
) -> str | None:
    """Reads the JSON blob written by External Secrets (the same shape that
    Secrets Manager stores for an RDS-managed secret)."""
    file = Path(path)
    if not file.exists():
        return None
    data = json.loads(file.read_text())
    user = quote_plus(data["username"])
    password = quote_plus(data["password"])
    host = data.get("host") or data["endpoint"]
    port = data.get("port", 5432)
    name = data.get("dbname", "aiplatform")
    return f"postgresql+asyncpg://{user}:{password}@{host}:{port}/{name}"


def build_engine(
    url: str,
    *,
    pool_size: int = 10,
    max_overflow: int = 5,
    statement_timeout_ms: int = 15_000,
) -> AsyncEngine:
    return create_async_engine(
        url,
        pool_size=pool_size,
        max_overflow=max_overflow,
        pool_pre_ping=True,  # survives an Aurora failover without a restart
        pool_recycle=1800,
        connect_args={
            "server_settings": {
                "application_name": os.getenv("POD_NAME", "ai-gateway"),
                # A runaway vector query must not hold a connection forever.
                "statement_timeout": str(statement_timeout_ms),
            },
            "ssl": "require",
        },
        echo=False,
    )
