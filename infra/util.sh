#!/bin/bash
# Shared helper functions for the infra scripts.

# Audience used to request a token for the Azure Managed Grafana REST API
GRAFANA_AAD_RESOURCE="ce34e7e5-485f-4d76-964f-b3d2b16d1e4f"
CYCLECLOUD_SLURM_VERSION="4.0.9"
CYCLECLOUD_SLURM_INSTALL_PACKAGE_SHA256="1356f9e1f4ac76e957ac4bb0a942c70df24ced0e14190e2a71d6170e221ffadb"
CYCLECLOUD_SLURM_INSTALL_PACKAGE_URL="https://github.com/Azure/cyclecloud-slurm/releases/download/${CYCLECLOUD_SLURM_VERSION}/azure-slurm-install-pkg-${CYCLECLOUD_SLURM_VERSION}.tar.gz"
CYCLECLOUD_SLURM_SOURCE_ARCHIVE_SHA256="5a0261f9afa116729fe842141944c6d4a0c1a61738bd03d322f2a56113304a88"
CYCLECLOUD_SLURM_SOURCE_ARCHIVE_URL="https://github.com/Azure/cyclecloud-slurm/archive/refs/tags/${CYCLECLOUD_SLURM_VERSION}.tar.gz"

require_option_value() {
  if [[ "$#" -lt 2 ]]; then
    echo "ERROR: Option '$1' requires a value" >&2
    exit 1
  fi
}

strip_carriage_returns() {
  if [[ "$#" -gt 0 ]]; then
    printf '%s' "$1" | tr -d '\r'
  else
    tr -d '\r'
  fi
}

download_cyclecloud_slurm_artifact() {
  if [[ "$#" -ne 2 ]]; then
    echo "download_cyclecloud_slurm_artifact: expected URL and destination" >&2
    return 1
  fi
  local artifact_url="$1"
  local destination="$2"

  curl --fail --silent --show-error --location "$artifact_url" -o "$destination"
}

download_verified_cyclecloud_slurm_artifact() {
  if [[ "$#" -ne 3 ]]; then
    echo "download_verified_cyclecloud_slurm_artifact: expected URL, destination, and SHA-256" >&2
    return 1
  fi
  local artifact_url="$1"
  local destination="$2"
  local expected_sha256="$3"

  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "download_verified_cyclecloud_slurm_artifact: sha256sum is required" >&2
    return 1
  fi
  if ! download_cyclecloud_slurm_artifact "$artifact_url" "$destination"; then
    return 1
  fi

  local actual_sha256
  actual_sha256=$(sha256sum "$destination" | cut -d' ' -f1)
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "download_verified_cyclecloud_slurm_artifact: SHA-256 checksum mismatch" >&2
    return 1
  fi
}

download_cyclecloud_slurm_install_package() {
  if [[ "$#" -ne 1 ]]; then
    echo "download_cyclecloud_slurm_install_package: expected destination" >&2
    return 1
  fi
  download_verified_cyclecloud_slurm_artifact \
    "$CYCLECLOUD_SLURM_INSTALL_PACKAGE_URL" "$1" \
    "$CYCLECLOUD_SLURM_INSTALL_PACKAGE_SHA256"
}

download_cyclecloud_slurm_source_archive() {
  if [[ "$#" -ne 1 ]]; then
    echo "download_cyclecloud_slurm_source_archive: expected destination" >&2
    return 1
  fi
  download_verified_cyclecloud_slurm_artifact \
    "$CYCLECLOUD_SLURM_SOURCE_ARCHIVE_URL" "$1" \
    "$CYCLECLOUD_SLURM_SOURCE_ARCHIVE_SHA256"
}

# az grafana has no library-panel command, so call the Grafana REST API directly.
# Upsert a single Grafana library panel.
# Usage: import_library_panel <library-panel-json>
# Requires the following variables to be set in the environment:
#   GRAFANA_ENDPOINT      - Grafana instance endpoint URL
import_library_panel() {
  local panel_file="$1"

  if [ -z "$panel_file" ]; then
    echo "import_library_panel: missing library panel json argument" >&2
    return 1
  fi
  if [ ! -f "$panel_file" ]; then
    echo "import_library_panel: file not found: $panel_file" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "import_library_panel: jq is required but was not found in PATH" >&2
    return 1
  fi

  local panel_uid panel_name existing_version payload
  panel_uid=$(jq -r '.uid // empty' "$panel_file")
  panel_name=$(jq -r '.name // empty' "$panel_file")

  if [ -z "$panel_uid" ] || [ -z "$panel_name" ]; then
    echo "import_library_panel: panel JSON must include non-empty .uid and .name: $panel_file" >&2
    return 1
  fi

  echo "Upserting library panel: $panel_name ($panel_uid)"

  if [ -z "${GRAFANA_ENDPOINT:-}" ]; then
    echo "import_library_panel: GRAFANA_ENDPOINT is not set" >&2
    return 1
  fi

  local existing_json
  existing_version=""
  if existing_json=$(az rest --method get \
    --url "$GRAFANA_ENDPOINT/api/library-elements/$panel_uid" \
    --resource "$GRAFANA_AAD_RESOURCE" 2>/dev/null); then
    existing_version=$(jq -r '.result.version // empty' <<<"$existing_json")
  fi

  if [ -z "$existing_version" ]; then
    # Create new library panel
    if az rest --method post \
      --url "$GRAFANA_ENDPOINT/api/library-elements" \
      --resource "$GRAFANA_AAD_RESOURCE" \
      --headers "Content-Type=application/json" \
      --body @"$panel_file" > /dev/null; then
      echo "  created"
    else
      echo "  failed to create $panel_uid" >&2
      return 1
    fi
  else
    # Update existing library panel (PATCH requires the current version)
    payload=$(jq --argjson v "$existing_version" '{name, kind, model, version: $v}' "$panel_file") || return 1
    if az rest --method patch \
      --url "$GRAFANA_ENDPOINT/api/library-elements/$panel_uid" \
      --resource "$GRAFANA_AAD_RESOURCE" \
      --headers "Content-Type=application/json" \
      --body "$payload" > /dev/null; then
      echo "  updated"
    else
      echo "  failed to update $panel_uid" >&2
      return 1
    fi
  fi
}
