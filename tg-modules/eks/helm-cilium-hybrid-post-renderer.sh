#!/bin/bash

python -m venv venv &> /dev/null
source venv/bin/activate &> /dev/null
pip install pyyaml &> /dev/null

export RBAC_SUFFIX="$1"
python helm-cilium-hybrid-post-renderer.py
