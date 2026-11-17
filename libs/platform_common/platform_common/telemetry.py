"""OpenTelemetry traces + Prometheus metrics.

Three principles that matter in an LLM platform and are easy to get wrong:
  1. Never put prompt or completion text on a span or a metric label. Prompts
     contain customer data; spans are shipped to a third-party backend.
  2. Cardinality discipline: label by tenant *tier* and model alias, never by
     tenant id or request id. Tenant-level cost lives in the ledger table.
  3. Token and cost are first-class metrics, not log lines. You cannot alert
     on a log line.
"""

from __future__ import annotations

import logging
import os
import sys
from contextlib import contextmanager

import structlog
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased


# --------------------------------------------------------------------------
# Tracing + logging
# --------------------------------------------------------------------------
def setup_telemetry(
    service_name: str,
    version: str,
    environment: str,
    otlp_endpoint: str,
    sample_ratio: float,
    log_level: str,
) -> None:
    resource = Resource.create(
        {
            "service.name": service_name,
            "service.version": version,
            "deployment.environment": environment,
            "k8s.pod.name": os.getenv("POD_NAME", ""),
            "k8s.namespace.name": os.getenv("POD_NAMESPACE", ""),
            "cloud.provider": "aws",
        }
    )

    provider = TracerProvider(
        resource=resource,
        sampler=ParentBased(root=TraceIdRatioBased(sample_ratio)),
    )
    if otlp_endpoint:
        provider.add_span_processor(
            BatchSpanProcessor(OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True))
        )
    trace.set_tracer_provider(provider)

    logging.basicConfig(
        format="%(message)s", stream=sys.stdout, level=log_level.upper()
    )
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            _inject_trace_context,
            _scrub,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, log_level.upper(), logging.INFO)
        ),
        cache_logger_on_first_use=True,
    )


def _inject_trace_context(_, __, event_dict: dict) -> dict:
    span = trace.get_current_span()
    ctx = span.get_span_context()
    if ctx and ctx.is_valid:
        event_dict["trace_id"] = format(ctx.trace_id, "032x")
        event_dict["span_id"] = format(ctx.span_id, "016x")
    return event_dict


_SENSITIVE_KEYS = {
    "prompt",
    "messages",
    "content",
    "completion",
    "api_key",
    "authorization",
    "password",
    "secret",
    "token",
}


def _scrub(_, __, event_dict: dict) -> dict:
    """Last line of defence. Application code should never log these, but a
    single careless `log.info("req", **payload)` would otherwise leak a prompt
    into CloudWatch, where it is retained for a year."""
    for key in list(event_dict):
        if key.lower() in _SENSITIVE_KEYS:
            event_dict[key] = "[redacted]"
    return event_dict


def get_logger(**bind):
    return structlog.get_logger().bind(**bind)


tracer = trace.get_tracer("ai-gateway")


@contextmanager
def span(name: str, **attributes):
    with tracer.start_as_current_span(name) as s:
        for k, v in attributes.items():
            if v is not None:
                s.set_attribute(k, v)
        yield s
