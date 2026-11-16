#!/usr/bin/env bash
set -euo pipefail
podman compose pull
systemctl restart savapage.service
