#!/usr/bin/env bash
set -euo pipefail

export SUFFIX="${RBAC_SUFFIX:-hybrid}"

yq eval -oy --no-doc '
  # Rename ClusterRole and ClusterRoleBinding names
  (select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .metadata.name) |= (. + "-" + strenv(SUFFIX))
  |
  # Update roleRef.name in ClusterRoleBinding (only when it refers to a ClusterRole)
  (select(.kind == "ClusterRoleBinding" and .roleRef.kind == "ClusterRole") | .roleRef.name) |= (. + "-" + strenv(SUFFIX))
' -
