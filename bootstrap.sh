#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Full automated deployment of ClickHouse GitOps stack
# =============================================================================
# Usage:
#   ./bootstrap.sh
#
# Or pass variables inline to skip prompts:
#   GITHUB_TOKEN=ghp_xxx GITHUB_USER=Dev-Mikael \
#   GITHUB_REPO=clickhouse-gitops CLICKHOUSE_PASSWORD=MyPass123 \
#   ./bootstrap.sh
#
# What this script does (fully automated, no manual steps):
#   1. Validates all required tools are installed
#   2. Validates cluster connectivity and Azure storage class
#   3. Bootstraps FluxCD into the cluster
#   4. Waits for the sealed-secrets controller to become Ready
#   5. Generates and seals the ClickHouse admin password
#   6. Commits and pushes the sealed secret to Git
#   7. Triggers immediate FluxCD reconciliation
#   8. Watches the full rollout until ClickHouse is healthy
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}══▶ $*${NC}"; }
die()     { error "$*"; exit 1; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        ClickHouse GitOps Bootstrap — Fully Automated        ║"
echo "║   FluxCD · Altinity Operator · ZooKeeper · Sealed Secrets   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
# STEP 1 — Collect configuration (env vars or interactive prompts)
# =============================================================================
step "Step 1/8 — Collecting configuration"

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  if [[ -z "${!var_name:-}" ]]; then
    read -rsp "${prompt_text}: " value
    echo
    export "$var_name"="$value"
  else
    info "$var_name already set via environment variable."
  fi
}

prompt_plain() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  if [[ -z "${!var_name:-}" ]]; then
    if [[ -n "$default" ]]; then
      read -rp "${prompt_text} [${default}]: " value
      export "$var_name"="${value:-$default}"
    else
      read -rp "${prompt_text}: " value
      export "$var_name"="$value"
    fi
  else
    info "$var_name already set via environment variable."
  fi
}

prompt_plain  GITHUB_USER      "GitHub username or org"
prompt_plain  GITHUB_REPO      "GitHub repository name" "clickhouse-gitops"
prompt_plain  GITHUB_BRANCH    "Git branch" "main"
prompt_secret GITHUB_TOKEN     "GitHub Personal Access Token (needs Contents: read+write)"
prompt_secret CLICKHOUSE_PASSWORD "ClickHouse admin password (min 12 chars, choose something strong)"

# Validate password length
if [[ ${#CLICKHOUSE_PASSWORD} -lt 12 ]]; then
  die "ClickHouse password must be at least 12 characters."
fi

# Storage class — default for AKS production; override if needed
STORAGE_CLASS="${STORAGE_CLASS:-managed-premium}"
FLUX_NAMESPACE="${FLUX_NAMESPACE:-flux-system}"
CLICKHOUSE_NAMESPACE="${CLICKHOUSE_NAMESPACE:-clickhouse}"
SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-sealed-secrets}"

echo
info "Configuration summary:"
echo "  GitHub user/org   : ${GITHUB_USER}"
echo "  Repository        : ${GITHUB_REPO}"
echo "  Branch            : ${GITHUB_BRANCH}"
echo "  Storage class     : ${STORAGE_CLASS}"
echo "  FluxCD namespace  : ${FLUX_NAMESPACE}"
echo "  ClickHouse ns     : ${CLICKHOUSE_NAMESPACE}"

# =============================================================================
# STEP 2 — Validate prerequisites
# =============================================================================
step "Step 2/8 — Validating prerequisites"

check_tool() {
  local tool="$1"
  local install_hint="$2"
  if command -v "$tool" &>/dev/null; then
    success "$tool found at $(command -v "$tool")"
  else
    die "$tool is required but not installed. $install_hint"
  fi
}

check_tool kubectl  "Install: https://kubernetes.io/docs/tasks/tools/"
check_tool flux     "Install: curl -s https://fluxcd.io/install.sh | sudo bash"
check_tool kubeseal "Install: https://github.com/bitnami-labs/sealed-secrets/releases"
check_tool git      "Install: https://git-scm.com/downloads"
check_tool curl     "Install via package manager (apt/brew/yum)"

# Cluster connectivity
info "Checking cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
  die "Cannot reach the Kubernetes cluster. Check your KUBECONFIG / kubectl context."
fi
CLUSTER_SERVER=$(kubectl cluster-info | grep "control plane" | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g')
success "Cluster reachable: ${CLUSTER_SERVER}"

# Cluster-admin check
info "Checking cluster-admin permissions..."
if ! kubectl auth can-i '*' '*' --all-namespaces &>/dev/null; then
  die "You need cluster-admin to bootstrap FluxCD. Check your kubeconfig role."
fi
success "cluster-admin permissions confirmed."

# Storage class check
info "Checking storage class '${STORAGE_CLASS}'..."
if ! kubectl get storageclass "${STORAGE_CLASS}" &>/dev/null; then
  warn "Storage class '${STORAGE_CLASS}' not found."
  info "Available storage classes:"
  kubectl get storageclass
  die "Set STORAGE_CLASS=<name> to match an available class and re-run."
fi
success "Storage class '${STORAGE_CLASS}' is available."

# Confirm the script is run from repo root
if [[ ! -f "apps/clickhouse/sealed-secret.yaml" ]]; then
  die "Run this script from the root of the clickhouse-gitops repository."
fi
success "Repository root confirmed."

# =============================================================================
# STEP 3 — Bootstrap FluxCD
# =============================================================================
step "Step 3/8 — Bootstrapping FluxCD"

info "Running flux bootstrap github..."
flux bootstrap github \
  --owner="${GITHUB_USER}" \
  --repository="${GITHUB_REPO}" \
  --branch="${GITHUB_BRANCH}" \
  --path="clusters/production" \
  --personal \
  --token-auth \
  --components-extra=image-reflector-controller,image-automation-controller 2>&1

success "FluxCD bootstrapped successfully."

# =============================================================================
# STEP 4 — Wait for sealed-secrets controller to be Ready
# =============================================================================
step "Step 4/8 — Waiting for Sealed Secrets controller"

info "Waiting for FluxCD to install sealed-secrets (may take 3-5 minutes)..."

# First wait for the HelmRelease to be created
TIMEOUT=300
INTERVAL=10
ELAPSED=0

until kubectl get helmrelease sealed-secrets -n "${SEALED_SECRETS_NAMESPACE}" &>/dev/null; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    die "Timed out waiting for sealed-secrets HelmRelease to appear. Check: flux get helmreleases --all-namespaces"
  fi
  info "Waiting for sealed-secrets HelmRelease... (${ELAPSED}s elapsed)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

# Wait for the actual controller pod to be Ready
info "HelmRelease found. Waiting for controller pod to be Ready..."
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=sealed-secrets \
  -n "${SEALED_SECRETS_NAMESPACE}" \
  --timeout=300s

success "Sealed Secrets controller is Ready."

# Give the controller a moment to fully initialise its key pair
sleep 5

# =============================================================================
# STEP 5 — Generate and seal the ClickHouse admin secret
# =============================================================================
step "Step 5/8 — Generating and sealing ClickHouse credentials"

info "Creating and sealing the ClickHouse admin secret..."

kubectl create secret generic clickhouse-credentials \
  --from-literal=admin-password="${CLICKHOUSE_PASSWORD}" \
  --namespace="${CLICKHOUSE_NAMESPACE}" \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace="${SEALED_SECRETS_NAMESPACE}" \
    --controller-name=sealed-secrets-controller \
    --format=yaml \
> apps/clickhouse/sealed-secret.yaml

# Verify the sealed secret was written correctly
if grep -q "REPLACE_WITH_SEALED_VALUE" apps/clickhouse/sealed-secret.yaml; then
  die "Sealed secret still contains placeholder — kubeseal may have failed."
fi

if ! grep -q "encryptedData" apps/clickhouse/sealed-secret.yaml; then
  die "Sealed secret file looks malformed — missing encryptedData block."
fi

success "Secret sealed successfully."
info "Sealed secret written to apps/clickhouse/sealed-secret.yaml"

# Clear the password from the environment immediately after sealing
unset CLICKHOUSE_PASSWORD

# =============================================================================
# STEP 6 — Commit and push the sealed secret
# =============================================================================
step "Step 6/8 — Committing and pushing sealed secret"

git add apps/clickhouse/sealed-secret.yaml

if git diff --cached --quiet; then
  warn "No changes to commit (sealed secret may already be up to date)."
else
  git commit -m "feat(clickhouse): add sealed admin credentials

Auto-generated by bootstrap.sh using kubeseal.
Plain-text password is NOT stored in this repository."

  info "Pushing to ${GITHUB_BRANCH}..."
  git push origin "${GITHUB_BRANCH}"
  success "Sealed secret pushed to Git."
fi

# =============================================================================
# STEP 7 — Trigger immediate FluxCD reconciliation
# =============================================================================
step "Step 7/8 — Triggering FluxCD reconciliation"

info "Forcing FluxCD to sync from Git immediately..."

flux reconcile source git flux-system
flux reconcile kustomization sources      --with-source
flux reconcile kustomization controllers  --with-source
flux reconcile kustomization apps         --with-source

success "Reconciliation triggered."

# =============================================================================
# STEP 8 — Watch the rollout
# =============================================================================
step "Step 8/8 — Watching deployment rollout"

info "Polling until all components are healthy. This takes 10-20 minutes."
info "Press Ctrl+C at any time — the deployment will continue in the background."
echo

# Track which checks have passed so we don't repeat success messages
ZK_DONE=false
OPERATOR_DONE=false
CHI_DONE=false
CERT_DONE=false
ALL_DONE=false

WATCH_TIMEOUT=1200   # 20 minutes total
WATCH_ELAPSED=0
WATCH_INTERVAL=15

while [[ $WATCH_ELAPSED -lt $WATCH_TIMEOUT ]]; do

  echo -e "${BOLD}── Status at ${WATCH_ELAPSED}s ─────────────────────────────────────${NC}"

  # ── FluxCD Kustomizations ──────────────────────────────────────────────────
  echo -e "${CYAN}FluxCD Kustomizations:${NC}"
  flux get kustomizations 2>/dev/null || true

  # ── ZooKeeper ──────────────────────────────────────────────────────────────
  if [[ "$ZK_DONE" == "false" ]]; then
    ZK_READY=$(kubectl get pods -n zookeeper \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    echo -e "\n${CYAN}ZooKeeper pods (need 3):${NC} ${ZK_READY}/3 Running"
    if [[ "$ZK_READY" -ge 3 ]]; then
      success "ZooKeeper quorum established."
      ZK_DONE=true
    fi
  else
    success "ZooKeeper ✓ (3/3 Running)"
  fi

  # ── ClickHouse Operator ────────────────────────────────────────────────────
  if [[ "$OPERATOR_DONE" == "false" ]]; then
    OP_READY=$(kubectl get pods -n clickhouse-operator \
      -l app=clickhouse-operator \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    echo -e "\n${CYAN}ClickHouse Operator:${NC} ${OP_READY} pod(s) Running"
    if [[ "$OP_READY" -ge 1 ]]; then
      success "ClickHouse Operator is running."
      OPERATOR_DONE=true
    fi
  else
    success "ClickHouse Operator ✓"
  fi

  # ── ClickHouse pods ────────────────────────────────────────────────────────
  echo -e "\n${CYAN}ClickHouse pods (need 4):${NC}"
  kubectl get pods -n "${CLICKHOUSE_NAMESPACE}" 2>/dev/null || echo "  (namespace not yet created)"

  if [[ "$CHI_DONE" == "false" ]]; then
    CH_READY=$(kubectl get pods -n "${CLICKHOUSE_NAMESPACE}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    if [[ "$CH_READY" -ge 4 ]]; then
      success "All 4 ClickHouse pods Running."
      CHI_DONE=true
    fi
  else
    success "ClickHouse pods ✓ (4/4 Running)"
  fi

  # ── TLS Certificate ────────────────────────────────────────────────────────
  if [[ "$CERT_DONE" == "false" ]]; then
    CERT_READY=$(kubectl get certificate clickhouse-tls \
      -n "${CLICKHOUSE_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    echo -e "\n${CYAN}TLS Certificate:${NC} Ready=${CERT_READY}"
    if [[ "$CERT_READY" == "True" ]]; then
      success "TLS certificate issued and Ready."
      CERT_DONE=true
    fi
  else
    success "TLS Certificate ✓"
  fi

  # ── ClickHouseInstallation status ──────────────────────────────────────────
  echo -e "\n${CYAN}ClickHouseInstallation status:${NC}"
  CHI_STATUS=$(kubectl get clickhouseinstallation clickhouse \
    -n "${CLICKHOUSE_NAMESPACE}" \
    -o jsonpath='{.status.status}' 2>/dev/null || echo "Pending")
  echo "  Status: ${CHI_STATUS}"

  if [[ "$CHI_STATUS" == "Completed" ]]; then
    CHI_DONE=true
  fi

  # ── All done? ──────────────────────────────────────────────────────────────
  if [[ "$ZK_DONE" == "true" && "$OPERATOR_DONE" == "true" && \
        "$CHI_DONE" == "true" && "$CERT_DONE" == "true" ]]; then
    ALL_DONE=true
    break
  fi

  echo -e "\n${YELLOW}Next check in ${WATCH_INTERVAL}s... (${WATCH_ELAPSED}s / ${WATCH_TIMEOUT}s)${NC}\n"
  sleep $WATCH_INTERVAL
  WATCH_ELAPSED=$((WATCH_ELAPSED + WATCH_INTERVAL))
done

# =============================================================================
# Final summary
# =============================================================================
echo
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"

if [[ "$ALL_DONE" == "true" ]]; then
  echo -e "${GREEN}${BOLD}  ✅  ClickHouse deployment complete!${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo
  echo -e "${BOLD}Connect to ClickHouse:${NC}"
  echo
  echo "  # Port-forward the native TCP port from any pod:"
  FIRST_POD=$(kubectl get pods -n "${CLICKHOUSE_NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "<pod-name>")
  echo "  kubectl port-forward pod/${FIRST_POD} 9000:9000 -n ${CLICKHOUSE_NAMESPACE}"
  echo
  echo "  # Then connect (in a new terminal):"
  echo "  clickhouse-client --host 127.0.0.1 --port 9000 --user admin --password <your-password> --secure"
  echo
  echo "  # Or exec directly into the pod:"
  echo "  kubectl exec -it pod/${FIRST_POD} -n ${CLICKHOUSE_NAMESPACE} -- clickhouse-client --user admin --password <your-password>"
  echo
  echo -e "${BOLD}Useful commands:${NC}"
  echo "  flux get kustomizations                        # FluxCD sync status"
  echo "  flux get helmreleases --all-namespaces         # Helm release status"
  echo "  kubectl get chi -n ${CLICKHOUSE_NAMESPACE}     # ClickHouseInstallation status"
  echo "  kubectl get pods --all-namespaces              # All pods"
else
  echo -e "${YELLOW}${BOLD}  ⏳  Deployment still in progress after ${WATCH_TIMEOUT}s.${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo
  warn "FluxCD is still running in the background — the deployment will complete."
  echo
  echo "Monitor with:"
  echo "  watch flux get kustomizations"
  echo "  watch kubectl get pods --all-namespaces"
  echo "  kubectl describe clickhouseinstallation clickhouse -n ${CLICKHOUSE_NAMESPACE}"
fi

echo
