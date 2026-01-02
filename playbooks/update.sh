#!/bin/bash

set -euo pipefail

# Usage function
usage() {
  echo "Usage: $0 [-i INPUT_YAML] [-o OUTPUT_YAML] [-d] [-h]"
  echo "  -i INPUT_YAML   Input YAML file (default: cns_values_16.0.yaml)"
  echo "  -o OUTPUT_YAML  Output YAML file (default: cns_values_16.2.yaml)"
  echo "  -d              Enable debug mode (set -x)"
  echo "  -h              Show this help message"
  echo ""
  echo "Environment Variables:"
  echo "  GITHUB_TOKEN    GitHub personal access token to avoid rate limiting"
  echo "                  (Create at: https://github.com/settings/tokens)"
  exit 1
}

# Default values
INPUT_YAML="cns_values_16.0.yaml"
OUTPUT_YAML="cns_values_16.2.yaml"
DEBUG=false

# Parse command line arguments
while getopts "i:o:dh" opt; do
  case $opt in
    i) INPUT_YAML="$OPTARG" ;;
    o) OUTPUT_YAML="$OPTARG" ;;
    d) DEBUG=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# Enable debug mode if requested
if [ "$DEBUG" = true ]; then
  set -x
fi

# Validate input file exists
if [ ! -f "$INPUT_YAML" ]; then
  echo "Error: Input file '$INPUT_YAML' not found!"
  exit 1
fi

TEMP_FILE=$(mktemp)
cp "$INPUT_YAML" "$TEMP_FILE"

# Cleanup temp file on exit
trap "rm -f $TEMP_FILE" EXIT

# Get latest stable tag from GitHub repo (strip 'v' prefix)
get_latest_github_version() {
  local repo="$1"
  local response
  local http_code
  local curl_args=(-s --max-time 30)
  
  # Add GitHub token if available
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: token $GITHUB_TOKEN")
  fi
  
  # Make request and capture both response and HTTP code
  response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "https://api.github.com/repos/$repo/tags?per_page=30" 2>&1)
  http_code=$(echo "$response" | tail -n1)
  response=$(echo "$response" | head -n-1)
  
  if [ "$http_code" != "200" ]; then
    echo "Warning: Failed to fetch version for $repo (HTTP $http_code)" >&2
    if [ "$DEBUG" = true ]; then
      echo "Response: ${response:0:500}" >&2
    fi
    # Check for rate limiting
    if [ "$http_code" = "403" ]; then
      echo "  Hint: GitHub API rate limit may be exceeded. Set GITHUB_TOKEN environment variable." >&2
    fi
    return 1
  fi
  
  if [ -z "$response" ]; then
    echo "Warning: Empty response for $repo" >&2
    return 1
  fi
  
  local version
  version=$(echo "$response" |
    sed -n 's/.*"name": "\([^"]*\)".*/\1/p' |
    grep -Ev 'rc|dev|alpha|beta' |
    sort -Vr |
    sed 's/^v//' |
    head -n1)
  
  if [ -z "$version" ]; then
    echo "Warning: No valid version found for $repo" >&2
    [ "$DEBUG" = true ] && echo "Response preview: ${response:0:200}" >&2
    return 1
  fi
  echo "$version"
}

# Get up to 6 latest stable tags from GitHub repo (strip 'v' prefix)
get_latest_github_versions() {
  local repo="$1"
  local response
  local http_code
  local curl_args=(-s --max-time 30)
  
  # Add GitHub token if available
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: token $GITHUB_TOKEN")
  fi
  
  # Make request and capture both response and HTTP code
  response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "https://api.github.com/repos/$repo/tags?per_page=100" 2>&1)
  http_code=$(echo "$response" | tail -n1)
  response=$(echo "$response" | head -n-1)
  
  if [ "$http_code" != "200" ]; then
    echo "Warning: Failed to fetch versions for $repo (HTTP $http_code)" >&2
    if [ "$DEBUG" = true ]; then
      echo "Response: ${response:0:500}" >&2
    fi
    if [ "$http_code" = "403" ]; then
      echo "  Hint: GitHub API rate limit may be exceeded. Set GITHUB_TOKEN environment variable." >&2
    fi
    return 1
  fi
  
  if [ -z "$response" ]; then
    echo "Warning: Empty response for $repo" >&2
    return 1
  fi
  
  echo "$response" |
    sed -n 's/.*"name": "\([^"]*\)".*/\1/p' |
    grep -Ev 'rc|dev|alpha|beta' |
    sed 's/^v//' |
    head -n6
}

# Get version from Helm Chart.yaml
get_helm_chart_version() {
  local repo_url="$1"
  local response
  response=$(curl -sf "$repo_url/Chart.yaml" 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$response" ]; then
    echo "Warning: Failed to fetch Chart.yaml from $repo_url" >&2
    return 1
  fi
  echo "$response" | awk '/version:/ {print $NF; exit}'
}

echo "--- Updating versions in $INPUT_YAML ---"

# Check for GitHub token
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "Note: GITHUB_TOKEN not set. You may hit rate limits (60 requests/hour)."
  echo "      To increase limit, create a token at https://github.com/settings/tokens"
  echo "      and run: export GITHUB_TOKEN=your_token_here"
  echo ""
fi

declare -A special_keys=(
  [cri_dockerd]="cri_dockerd_version"
  [nvidia_container_toolkit]="nvidia_container_toolkit_version"
  [gpu_operator]="gpu_operator_version"
  [network_operator]="network_operator_version"
  [k8s_nim_operator]="nim_operator_version"
  [k8s_dra_driver_gpu]="dra_driver_version"
  [lws]="lws_version"
  [volcano]="volcano_version"
  [dynamo]="dynamo_release_version"
  [kai_scheduler]="kai_scheduler_version"
  [elasticsearch]="elastic_stack"
)

repos=(
  "containerd/containerd"
  "opencontainers/runc"
  "containernetworking/plugins"
  "Mirantis/cri-dockerd"
  "projectcalico/calico"
  "NVIDIA/nvidia-container-toolkit"
  "helm/helm"
  "rancher/local-path-provisioner"
  "metallb/metallb"
  "kserve/kserve"
  "grafana/grafana-operator"
  "kubernetes-sigs/lws"
  "elastic/elasticsearch"
  "NVIDIA/gpu-operator"
  "Mellanox/network-operator"
  "NVIDIA/k8s-nim-operator"
  "NVIDIA/k8s-dra-driver-gpu"
  "ai-dynamo/dynamo"
  "volcano-sh/volcano"
  "NVIDIA/KAI-Scheduler"
)

reposk=(
  "kubernetes/kubernetes"
  "cri-o/cri-o"
)

# Update most repos
for repo in "${repos[@]}"; do
  echo "Fetching version for $repo..."
  version=$(get_latest_github_version "$repo")
  if [[ -z "$version" ]]; then
    echo "Warning: Skipping $repo - no version found" >&2
    continue
  fi
  key=$(basename "$repo" | tr '-' '_' | tr '[:upper:]' '[:lower:]')
  key_version="${special_keys[$key]:-${key}_version}"
  sed -i "s/^$key_version: .*/$key_version: \"$version\"/" "$TEMP_FILE"
  echo "✓ Updated $key_version to: $version"
done

# Update k8s/crio with matching major.minor
echo "Fetching Kubernetes and CRI-O versions..."
k8s_versions=$(get_latest_github_versions "kubernetes/kubernetes")
crio_versions=$(get_latest_github_versions "cri-o/cri-o")

if [[ -n "$k8s_versions" ]]; then
  # Find all major.minor.patch versions, sort, and get the previous major
  prev_major=$(echo "$k8s_versions" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | \
    awk -F. '{versions[$1]=$1} END {n=asorti(versions,a); if(n>1) print versions[a[n-1]]; else print versions[a[1]]}')
  if [[ -n "$prev_major" ]]; then
    # Now find all versions for that previous major, sort descending, and pick the latest minor.patch
    latest_prev_major_version=$(echo "$k8s_versions" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | \
      awk -F. -v major="$prev_major" '$1==major' | sort -Vr | head -n1)
    if [[ -n "$latest_prev_major_version" ]]; then
      sed -i "s/^k8s_version: .*/k8s_version: \"$latest_prev_major_version\"/" "$TEMP_FILE"
      echo "✓ Updated k8s_version to: $latest_prev_major_version"
    else
      echo "Warning: Could not find a version for previous Kubernetes major ($prev_major)" >&2
    fi
  else
    echo "Warning: Could not compute previous Kubernetes major version" >&2
    [ "$DEBUG" = true ] && echo "Versions received: $k8s_versions" >&2
  fi
else
  echo "Warning: Failed to fetch Kubernetes versions" >&2
fi

if [[ -n "$crio_versions" ]]; then
  crio_major_minor=$(awk '/crio_version:/ {gsub(/"/,"",$2); split($2,a,"."); print a[1]"."a[2]}' "$TEMP_FILE")
  if [[ -n "$crio_major_minor" ]]; then
    crio_version=$(grep -m1 "$crio_major_minor" <<< "$crio_versions" | sed 's/^v//' || true)
    if [[ -n "$crio_version" ]]; then
      sed -i "s/crio_version: .*/crio_version: \"$crio_version\"/" "$TEMP_FILE"
      echo "✓ Updated crio_version to: $crio_version"
    else
      echo "Warning: No matching CRI-O version found for $crio_major_minor" >&2
    fi
  fi
else
  echo "Warning: Failed to fetch CRI-O versions" >&2
fi

# NFS provisioner
echo "Fetching NFS provisioner version..."
curl_args=(-s)
if [ -n "${GITHUB_TOKEN:-}" ]; then
  curl_args+=(-H "Authorization: token $GITHUB_TOKEN")
fi
nfs_response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "https://api.github.com/repos/kubernetes-sigs/nfs-subdir-external-provisioner/releases/latest" 2>&1)
http_code=$(echo "$nfs_response" | tail -n1)
nfs_response=$(echo "$nfs_response" | head -n-1)

if [[ "$http_code" = "200" ]] && [[ -n "$nfs_response" ]]; then
  nfs_provisioner_version=$(echo "$nfs_response" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/^v//' | awk -F'-' '{print $NF}')
  if [[ -n "$nfs_provisioner_version" ]]; then
    sed -i "s/^nfs_provisioner: .*/nfs_provisioner: \"$nfs_provisioner_version\"/" "$TEMP_FILE"
    echo "✓ Updated nfs_provisioner to: $nfs_provisioner_version"
  fi
else
  echo "Warning: Failed to fetch NFS provisioner version (HTTP $http_code)" >&2
  [ "$DEBUG" = true ] && echo "Response: ${nfs_response:0:200}" >&2
fi

# Prometheus Stack
echo "Fetching Prometheus Stack version..."
prometheus_stack_version=$(get_helm_chart_version "https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack")
if [[ -n "$prometheus_stack_version" ]]; then
  sed -i "s/^prometheus_stack: .*/prometheus_stack: \"$prometheus_stack_version\"/" "$TEMP_FILE"
  echo "✓ Updated prometheus_stack to: $prometheus_stack_version"
else
  echo "Warning: Failed to fetch Prometheus Stack version" >&2
fi

# Prometheus Adapter
echo "Fetching Prometheus Adapter version..."
prometheus_adapter_version=$(get_helm_chart_version "https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/prometheus-adapter")
if [[ -n "$prometheus_adapter_version" ]]; then
  sed -i "s/^prometheus_adapter: .*/prometheus_adapter: \"$prometheus_adapter_version\"/" "$TEMP_FILE"
  echo "✓ Updated prometheus_adapter to: $prometheus_adapter_version"
else
  echo "Warning: Failed to fetch Prometheus Adapter version" >&2
fi

# Ingress Controller
echo "Fetching Ingress Controller version..."
ingress_response=$(curl -s -w "\n%{http_code}" https://artifacthub.io/api/v1/packages/helm/ingress-nginx/ingress-nginx 2>&1)
http_code=$(echo "$ingress_response" | tail -n1)
ingress_response=$(echo "$ingress_response" | head -n-1)

if [[ "$http_code" = "200" ]] && [[ -n "$ingress_response" ]]; then
  ingress_controller_version=$(echo "$ingress_response" | grep -o '"version":"[^"]*"' | head -1 | sed 's/"version":"//;s/"//')
  if [[ -n "$ingress_controller_version" ]]; then
    sed -i "s/^ingress_controller_version: .*/ingress_controller_version: \"$ingress_controller_version\"/" "$TEMP_FILE"
    echo "✓ Updated Ingress Controller to: $ingress_controller_version"
  fi
else
  echo "Warning: Failed to fetch Ingress Controller version (HTTP $http_code)" >&2
  [ "$DEBUG" = true ] && echo "Response: ${ingress_response:0:200}" >&2
fi

mv "$TEMP_FILE" "$OUTPUT_YAML"
if [ $? -eq 0 ]; then
  echo ""
  echo "=========================================="
  echo "✓ Update complete!"
  echo "  New versions saved to: $OUTPUT_YAML"
  echo "=========================================="
else
  echo "Error: Failed to save output file to $OUTPUT_YAML" >&2
  exit 1
fi