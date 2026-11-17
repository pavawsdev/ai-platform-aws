"""Shared platform primitives: telemetry, database wiring, resilience helpers.

Published to CodeArtifact and pinned by digest in each service's
requirements.txt. Keeping this in one place is what makes "every service emits
the same trace attributes and scrubs the same fields" true by construction
rather than by convention.
"""

__version__ = "1.0.0"
