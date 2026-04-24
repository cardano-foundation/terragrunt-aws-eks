#!/usr/bin/env python3
import os
import sys
from typing import Any, Dict, Iterable

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "PyYAML is required. Install with: pip install pyyaml\n"
    )
    sys.exit(1)

SUFFIX = os.environ.get("RBAC_SUFFIX", "secondary")

# If set, only rename objects whose name starts with this prefix (e.g. "cilium-").
# Leave empty to rename all ClusterRole/ClusterRoleBinding in the rendered output.
NAME_PREFIX = os.environ.get("RBAC_PREFIX", "")

# If "true", rename ServiceAccounts too and fix ClusterRoleBinding subjects accordingly.
RENAME_SERVICEACCOUNTS = os.environ.get("RENAME_SERVICEACCOUNTS", "false").lower() in ("1","true","yes","y")

def should_rename(name: str) -> bool:
    if not name:
        return False
    if NAME_PREFIX:
        return name.startswith(NAME_PREFIX)
    return True

def rename(name: str) -> str:
    return f"{name}-{SUFFIX}"

def iter_docs(stream: str) -> Iterable[Any]:
    # Safe-load all docs; keep empty docs as None so we can round-trip doc count
    return yaml.safe_load_all(stream)

def dump_docs(docs: Iterable[Any]) -> str:
    # explicit_start=True ensures '---' between docs so Helm keeps them separate.
    return yaml.safe_dump_all(
        list(docs),
        explicit_start=True,
        default_flow_style=False,
        sort_keys=False,
    )

raw = sys.stdin.read()
docs_in = list(iter_docs(raw))

docs_out = []
for doc in docs_in:
    if not isinstance(doc, dict):
        docs_out.append(doc)
        continue

    kind = doc.get("kind")
    meta = doc.get("metadata") or {}
    name = meta.get("name") or ""

    # Rename ClusterRole / ClusterRoleBinding
    if kind in ("ClusterRole", "ClusterRoleBinding") and should_rename(name):
        meta["name"] = rename(name)
        doc["metadata"] = meta

    # Update roleRef.name in ClusterRoleBinding
    if kind == "ClusterRoleBinding":
        role_ref: Dict[str, Any] = doc.get("roleRef") or {}
        if role_ref.get("kind") == "ClusterRole":
            rr_name = role_ref.get("name") or ""
            if should_rename(rr_name):
                role_ref["name"] = rename(rr_name)
                doc["roleRef"] = role_ref

        # Optionally rename ServiceAccount subjects (rarely needed just to fix collisions,
        # but included because you referenced the serviceaccount.yaml)
        if RENAME_SERVICEACCOUNTS:
            subjects = doc.get("subjects") or []
            for s in subjects:
                if not isinstance(s, dict):
                    continue
                if s.get("kind") == "ServiceAccount" and s.get("name") and should_rename(s["name"]):
                    s["name"] = rename(s["name"])
            doc["subjects"] = subjects

    # Optionally rename ServiceAccount objects themselves
    if RENAME_SERVICEACCOUNTS and kind == "ServiceAccount" and should_rename(name):
        meta["name"] = rename(name)
        doc["metadata"] = meta

    docs_out.append(doc)

sys.stdout.write(dump_docs(docs_out))
