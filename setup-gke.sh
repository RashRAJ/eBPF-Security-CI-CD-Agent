#!/bin/bash
set -e

# Colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration variables
CLUSTER_NAME="github-runners"
GITHUB_TOKEN=""
RUNNER_NAMESPACE="arc-runners"
CONTROLLER_NAMESPACE="arc-systems"
# Set these variables for your specific use case
GITHUB_OWNER=""
GITHUB_REPO=""
RUNNER_NAME=""
# GKE specific configuration
GKE_REGION="europe-west4"
GKE_PROJECT_ID=""
GKE_NODE_COUNT="2"  # Reduced from 3 to 2
GKE_MIN_NODES="1"
GKE_MAX_NODES="3"   # Reduced from 5 to 3
GKE_MACHINE_TYPE="t2a-standard-2" # ARM-based machine type
GKE_DISK_SIZE="50"  # Set explicit disk size to control SSD usage (GB)
# Directory for runner YAML files
MANIFESTS_DIR="./runner-manifests"
# Chart version - set to 0.10.0 to avoid YAML parsing errors
CHART_VERSION="0.10.0"

# Function to display usage information
usage() {
    echo "GitHub Self-Hosted Runner Setup Script for GKE"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  create         Create GKE cluster and deploy GitHub runners"
    echo "  destroy        Destroy GKE cluster"
    echo "  deploy         Deploy GitHub runners to existing cluster"
    echo "  clean          Remove old CRDs from the cluster"
    echo ""
    echo "Options:"
    echo "  --token=<token>       GitHub Personal Access Token (required for create/deploy)"
    echo "  --owner=<org/user>    GitHub organization or username"
    echo "  --repo=<repo>         GitHub repository name (if empty, runners will be org-level)"
    echo "  --name=<name>         Name for runner (required for variable substitution in manifests)"
    echo "  --version=<version>   Chart version to use (default: ${CHART_VERSION})"
    echo "  --project=<project>   GCP Project ID (required for GKE operations)"
    echo "  --region=<region>     GCP Region for cluster (default: ${GKE_REGION})"
    echo "  --node-count=<count>  Initial node count (default: ${GKE_NODE_COUNT})"
    echo "  --min-nodes=<count>   Minimum nodes for autoscaling (default: ${GKE_MIN_NODES})"
    echo "  --max-nodes=<count>   Maximum nodes for autoscaling (default: ${GKE_MAX_NODES})"
    echo "  --disk-size=<size>    Disk size in GB (default: ${GKE_DISK_SIZE})"
    echo ""
    echo "Examples:"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --repo=myrepo --name=myrunner --project=my-gcp-project"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --name=myrunner --project=my-gcp-project --region=us-west1"
    echo "  $0 clean --project=my-gcp-project"
    echo "  $0 destroy --project=my-gcp-project"
    exit 1
}

# Parse command line arguments
parse_args() {
    for arg in "$@"; do
        case $arg in
            --token=*)
                GITHUB_TOKEN="${arg#*=}"
                ;;
            --owner=*)
                GITHUB_OWNER="${arg#*=}"
                ;;
            --repo=*)
                GITHUB_REPO="${arg#*=}"
                ;;
            --name=*)
                RUNNER_NAME="${arg#*=}"
                ;;
            --version=*)
                CHART_VERSION="${arg#*=}"
                ;;
            --project=*)
                GKE_PROJECT_ID="${arg#*=}"
                ;;
            --region=*)
                GKE_REGION="${arg#*=}"
                ;;
            --node-count=*)
                GKE_NODE_COUNT="${arg#*=}"
                ;;
            --min-nodes=*)
                GKE_MIN_NODES="${arg#*=}"
                ;;
            --max-nodes=*)
                GKE_MAX_NODES="${arg#*=}"
                ;;
            --disk-size=*)
                GKE_DISK_SIZE="${arg#*=}"
                ;;
            *)
                # Unknown option
                ;;
        esac
    done
}

# Function to check required tools
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check for gcloud
    if ! command -v gcloud &> /dev/null; then
        echo -e "${RED}Error: gcloud CLI is not installed. Please install gcloud first.${NC}"
        echo "Visit: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    # Check for kubectl
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl is not installed. Please install kubectl first.${NC}"
        echo "Visit: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        exit 1
    fi
    
    # Check for helm
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}Error: helm is not installed. Please install helm first.${NC}"
        echo "Visit: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    echo -e "${GREEN}All prerequisites are installed.${NC}"
}

# Function to check if required files exist
check_required_files() {
    # Check for runner values file
    if [ ! -f "${MANIFESTS_DIR}/runner-values.yaml" ]; then
        echo -e "${RED}Error: Runner values file not found at ${MANIFESTS_DIR}/runner-values.yaml${NC}"
        exit 1
    fi
    
    # Check for controller values file
    if [ ! -f "${MANIFESTS_DIR}/controller-values.yaml" ]; then
        echo -e "${RED}Error: Controller values file not found at ${MANIFESTS_DIR}/controller-values.yaml${NC}"
        exit 1
    fi
}

# Check for required GCP project ID
check_gcp_project() {
    if [ -z "$GKE_PROJECT_ID" ]; then
        echo -e "${RED}Error: GCP Project ID is required. Use --project=<project-id>${NC}"
        exit 1
    fi
    
    # Set the active project
    echo -e "${YELLOW}Setting active GCP project to ${GKE_PROJECT_ID}...${NC}"
    gcloud config set project "$GKE_PROJECT_ID"
}

# Function to calculate and validate resource usage against quotas
check_resource_usage() {
    echo -e "${YELLOW}Checking quota requirements...${NC}"
    
    # Calculate expected CPU usage
    local expected_cpus=$((GKE_NODE_COUNT * 2))  # t2a-standard-2 has 2 CPUs per node
    
    # Calculate expected SSD usage (50GB per node by default, or custom size)
    local expected_ssd=$((GKE_NODE_COUNT * GKE_DISK_SIZE))
    
    echo "Resource request - T2A CPUs: ${expected_cpus}, SSD Storage: ${expected_ssd}GB"
    
    # Check if our expected usage is within quota
    if [ $expected_cpus -gt 8 ]; then
        echo -e "${RED}Warning: Your configuration requires ${expected_cpus} T2A CPUs, but your quota is only 8 CPUs.${NC}"
        echo -e "${RED}Consider reducing node count or using a smaller machine type.${NC}"
        return 1
    fi
    
    if [ $expected_ssd -gt 250 ]; then
        echo -e "${RED}Warning: Your configuration requires ${expected_ssd}GB of SSD storage, but your quota is only 250GB.${NC}"
        echo -e "${RED}Consider reducing disk size or node count.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Resource request is within quota limits.${NC}"
    return 0
}

# Function to create the GKE cluster
create_cluster() {
    echo -e "${YELLOW}Checking if cluster '${CLUSTER_NAME}' already exists in project ${GKE_PROJECT_ID}, region ${GKE_REGION}...${NC}"
    
    # Validate resource usage against quotas
    check_resource_usage || {
        echo -e "${RED}Error: Resource requirements exceed available quota. Aborting cluster creation.${NC}"
        echo "You can request quota increases at: https://console.cloud.google.com/iam-admin/quotas?usage=USED&project=${GKE_PROJECT_ID}"
        exit 1
    }
    
    # Check if cluster already exists
    if gcloud container clusters list --project="$GKE_PROJECT_ID" --region="$GKE_REGION" --filter="name=$CLUSTER_NAME" | grep -q "$CLUSTER_NAME"; then
        echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' already exists.${NC}"
        echo -e "${YELLOW}Using existing cluster.${NC}"
    else
        echo -e "${YELLOW}Creating GKE cluster '${CLUSTER_NAME}'...${NC}"
        
        # Create a GKE cluster with ARM nodes and latest COS with containerd
        # Use only a single zone if needed to reduce resource requirements
        gcloud container clusters create "$CLUSTER_NAME" \
            --project="$GKE_PROJECT_ID" \
            --region="$GKE_REGION" \
            --machine-type="$GKE_MACHINE_TYPE" \
            --num-nodes="$GKE_NODE_COUNT" \
            --min-nodes="$GKE_MIN_NODES" \
            --max-nodes="$GKE_MAX_NODES" \
            --enable-autoscaling \
            --node-locations="${GKE_REGION}-a" \
            --disk-size="$GKE_DISK_SIZE" \
            --image-type="COS_CONTAINERD" \
            --enable-ip-alias \
            --workload-pool="${GKE_PROJECT_ID}.svc.id.goog" \
            --no-enable-master-authorized-networks
        
        echo -e "${GREEN}GKE cluster '${CLUSTER_NAME}' created successfully.${NC}"
    fi
    
    # Get credentials for the cluster
    echo -e "${YELLOW}Getting credentials for cluster...${NC}"
    gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$GKE_REGION" --project="$GKE_PROJECT_ID"
    
    # Display cluster info
    echo -e "${YELLOW}Cluster information:${NC}"
    kubectl cluster-info
}

# Function to update variables in YAML file
update_yaml_with_vars() {
    local file=$1
    local dest=$2
    echo "Updating $file with variable substitution to $dest..."
    
    # Replace variables with their values
    cat "$file" | \
        sed "s|\${GITHUB_TOKEN}|${GITHUB_TOKEN}|g" | \
        sed "s|\${RUNNER_NAME}|${RUNNER_NAME}|g" | \
        sed "s|\${GITHUB_OWNER}|${GITHUB_OWNER}|g" | \
        sed "s|\${GITHUB_REPO}|${GITHUB_REPO}|g" | \
        sed "s|\${RUNNER_NAMESPACE}|${RUNNER_NAMESPACE}|g" > "$dest"
    
    echo "File updated: $dest"
}

# Function to clean up old CRDs
cleanup_old_crds() {
    echo -e "${YELLOW}Cleaning up old CRDs...${NC}"
    
    # Remove old CRDs that might cause conflicts
    kubectl delete crd autoscalingrunnersets.actions.github.com --ignore-not-found=true
    kubectl delete crd ephemeralrunners.actions.github.com --ignore-not-found=true
    kubectl delete crd ephemeralrunnerpods.actions.github.com --ignore-not-found=true
    kubectl delete crd ephemeralrunnersets.actions.github.com --ignore-not-found=true
    
    # Check if there are any helm releases to clean up
    if kubectl get namespace ${RUNNER_NAMESPACE} &>/dev/null; then
        echo "Cleaning up existing runner releases in namespace ${RUNNER_NAMESPACE}..."
        # List all helm releases in the runner namespace and delete them
        helm list -n ${RUNNER_NAMESPACE} -q | xargs -r helm uninstall -n ${RUNNER_NAMESPACE}
    fi
    
    if kubectl get namespace ${CONTROLLER_NAMESPACE} &>/dev/null; then
        echo "Cleaning up existing controller releases in namespace ${CONTROLLER_NAMESPACE}..."
        # List all helm releases in the controller namespace and delete them
        helm list -n ${CONTROLLER_NAMESPACE} -q | xargs -r helm uninstall -n ${CONTROLLER_NAMESPACE}
    fi
    
    echo -e "${GREEN}Cleanup completed.${NC}"
}

# Function to deploy GitHub runners
deploy_runners() {
    if [ -z "$GITHUB_TOKEN" ]; then
        echo -e "${RED}Error: GitHub token is required. Use --token=<your-token>${NC}"
        exit 1
    fi
    
    if [ -z "$GITHUB_OWNER" ]; then
        echo -e "${RED}Error: GitHub owner is required. Use --owner=<org/user>${NC}"
        exit 1
    fi
    
    if [ -z "$RUNNER_NAME" ]; then
        echo -e "${RED}Error: Runner name is required. Use --name=<runner-name>${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Preparing for GitHub Actions Runners deployment using chart version ${CHART_VERSION}...${NC}"
    
    # Create temporary files with variable substitution
    TEMP_CONTROLLER_VALUES=$(mktemp)
    TEMP_RUNNER_VALUES=$(mktemp)
    
    update_yaml_with_vars "${MANIFESTS_DIR}/controller-values.yaml" "$TEMP_CONTROLLER_VALUES"
    update_yaml_with_vars "${MANIFESTS_DIR}/runner-values.yaml" "$TEMP_RUNNER_VALUES"
    
    echo -e "${YELLOW}Deploying GitHub Actions Runner Controller...${NC}"
    
    # Handle ARM architecture by removing the architecture taint
    echo -e "${YELLOW}Checking for architecture taints on nodes...${NC}"
    if kubectl get nodes -o jsonpath='{.items[*].spec.taints[?(@.key=="kubernetes.io/arch")]}' | grep -q "arm64"; then
        echo -e "${YELLOW}Found architecture taints. Removing kubernetes.io/arch taints from nodes...${NC}"
        kubectl taint nodes --all kubernetes.io/arch-
    else
        echo -e "${GREEN}No architecture taints found.${NC}"
    fi
    
    # Install cert-manager (required for actions-runner-controller)
    echo "Installing cert-manager..."
    
    # Check if cert-manager is already installed
    if kubectl get namespace cert-manager &>/dev/null; then
        echo "cert-manager namespace already exists, checking deployments..."
        if kubectl get deployment -n cert-manager | grep -q cert-manager; then
            echo "cert-manager appears to be already installed, skipping installation."
        else
            echo "cert-manager namespace exists but deployments not found, reinstalling..."
            kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.yaml
            # Wait for namespace to be properly setup
            sleep 30
        fi
    else
        echo "Installing cert-manager from scratch..."
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.yaml
        # Wait for namespace to be properly setup
        sleep 30
    fi
    
    # Patch cert-manager deployments with ARM64 tolerations (in case taint removal didn't work)
    echo "Adding ARM64 tolerations to cert-manager deployments..."
    
    # Function to patch a deployment with ARM64 tolerations
    patch_deployment_for_arm64() {
        local deployment=$1
        echo "Patching $deployment with ARM64 tolerations..."
        
        # Check if deployment exists
        if kubectl get deployment $deployment -n cert-manager &>/dev/null; then
            # Add tolerations using kubectl patch
            kubectl patch deployment $deployment -n cert-manager --type=json -p='[
              {
                "op": "add", 
                "path": "/spec/template/spec/tolerations", 
                "value": [{"key": "kubernetes.io/arch", "operator": "Equal", "value": "arm64", "effect": "NoSchedule"}]
              }
            ]' || echo "Failed to patch $deployment, but continuing..."
        else
            echo "Deployment $deployment not found yet, skipping patch."
        fi
    }
    
    # Patch all cert-manager deployments
    patch_deployment_for_arm64 cert-manager
    patch_deployment_for_arm64 cert-manager-cainjector
    patch_deployment_for_arm64 cert-manager-webhook
    
    # Wait for cert-manager to be ready with improved error handling
    echo "Waiting for cert-manager to be ready..."
    
    # Increase timeout and add retry logic
    TIMEOUT=600  # 10 minutes instead of 5
    RETRY_COUNT=0
    MAX_RETRIES=3
    
    wait_for_deployment() {
        local deployment=$1
        echo "Waiting for ${deployment} to be ready..."
        if ! kubectl wait --for=condition=available --timeout=${TIMEOUT}s deployment/${deployment} -n cert-manager; then
            echo -e "${YELLOW}Warning: Timed out waiting for ${deployment}. Checking deployment status...${NC}"
            kubectl get deployment/${deployment} -n cert-manager -o wide
            kubectl describe deployment/${deployment} -n cert-manager
            return 1
        fi
        return 0
    }
    
    # Try to wait for all cert-manager components with retries
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if wait_for_deployment "cert-manager" && \
           wait_for_deployment "cert-manager-webhook" && \
           wait_for_deployment "cert-manager-cainjector"; then
            echo -e "${GREEN}All cert-manager components are ready.${NC}"
            break
        else
            RETRY_COUNT=$((RETRY_COUNT+1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo -e "${YELLOW}Retry ${RETRY_COUNT}/${MAX_RETRIES}: Waiting for cert-manager components...${NC}"
                echo "Checking cert-manager namespace for issues:"
                kubectl get pods -n cert-manager
                echo "Waiting 60 seconds before retrying..."
                sleep 60
            else
                echo -e "${YELLOW}Warning: Could not confirm all cert-manager components are ready after ${MAX_RETRIES} attempts.${NC}"
                echo -e "${YELLOW}Proceeding anyway, but you may need to check cert-manager manually.${NC}"
                # Continue despite the error - sometimes cert-manager works even when the wait times out
            fi
        fi
    done
    
    # Create controller namespace
    echo "Creating controller namespace..."
    kubectl create namespace $CONTROLLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    
    # Create runner namespace
    echo "Creating runner namespace..."
    kubectl create namespace ${RUNNER_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    # Check if controller is already installed and uninstall it first
    if helm list -n $CONTROLLER_NAMESPACE | grep -q "arc"; then
        echo "Uninstalling existing controller release..."
        helm uninstall arc -n $CONTROLLER_NAMESPACE
        # Wait a bit for resources to be cleaned up
        sleep 10
    fi
    
    # Add ARM64 tolerations to the controller installation
    echo "Creating custom values file with ARM64 tolerations for controller..."
    cat > "$TEMP_CONTROLLER_VALUES.arm64" << EOF
$(cat "$TEMP_CONTROLLER_VALUES")
runner:
  tolerations:
  - key: "kubernetes.io/arch"
    operator: "Equal"
    value: "arm64"
    effect: "NoSchedule"
controller:
  tolerations:
  - key: "kubernetes.io/arch"
    operator: "Equal"
    value: "arm64"
    effect: "NoSchedule"
EOF
    TEMP_CONTROLLER_VALUES="$TEMP_CONTROLLER_VALUES.arm64"
    
    # Install the controller using the official OCI chart with version
    echo "Installing/upgrading gha-runner-scale-set-controller version ${CHART_VERSION}..."
    helm upgrade --install arc \
      --namespace $CONTROLLER_NAMESPACE \
      -f "$TEMP_CONTROLLER_VALUES" \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller --version=${CHART_VERSION}
    
    # Wait for controller to be ready with correct deployment name
    echo "Waiting for controller to be ready..."
    # Give some time for the deployment to be created
    sleep 20
    
    # Try to wait for controller with improved error handling
    MAX_ATTEMPTS=3
    ATTEMPT=1
    CONTROLLER_READY=false
    
    while [ $ATTEMPT -le $MAX_ATTEMPTS ] && [ "$CONTROLLER_READY" = "false" ]; do
        echo "Attempt $ATTEMPT/$MAX_ATTEMPTS: Checking controller deployment..."
        
        # Check if the deployment exists first
        if kubectl get deployment/arc-gha-rs-controller -n $CONTROLLER_NAMESPACE &>/dev/null; then
            echo "Controller deployment found, waiting for it to be available..."
            if kubectl wait --for=condition=available --timeout=300s deployment/arc-gha-rs-controller -n $CONTROLLER_NAMESPACE; then
                CONTROLLER_READY=true
                echo -e "${GREEN}Controller is ready.${NC}"
            else
                echo -e "${YELLOW}Timed out waiting for controller deployment.${NC}"
                kubectl get deployment/arc-gha-rs-controller -n $CONTROLLER_NAMESPACE -o wide
                kubectl describe deployment/arc-gha-rs-controller -n $CONTROLLER_NAMESPACE
            fi
        else
            echo -e "${YELLOW}Controller deployment not found yet. Listing all resources in namespace...${NC}"
            kubectl get all -n $CONTROLLER_NAMESPACE
        fi
        
        if [ "$CONTROLLER_READY" = "false" ]; then
            if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
                echo "Waiting 30 seconds before retry..."
                sleep 30
            else
                echo -e "${YELLOW}Warning: Controller not confirmed ready after $MAX_ATTEMPTS attempts.${NC}"
                echo -e "${YELLOW}Proceeding anyway. You may need to check the controller status manually.${NC}"
            fi
            ATTEMPT=$((ATTEMPT+1))
        fi
    done
    
    # Check if runner scale set is already installed and uninstall it first
    if helm list -n $RUNNER_NAMESPACE | grep -q "$RUNNER_NAME"; then
        echo "Uninstalling existing runner scale set release..."
        helm uninstall $RUNNER_NAME -n $RUNNER_NAMESPACE
        # Wait a bit for resources to be cleaned up
        sleep 10
    fi
    
    # Add ARM64 tolerations to the runner scale set
    echo "Creating custom values file with ARM64 tolerations for runner scale set..."
    cat > "$TEMP_RUNNER_VALUES.arm64" << EOF
$(cat "$TEMP_RUNNER_VALUES")
template:
  spec:
    tolerations:
    - key: "kubernetes.io/arch"
      operator: "Equal"
      value: "arm64"
      effect: "NoSchedule"
EOF
    TEMP_RUNNER_VALUES="$TEMP_RUNNER_VALUES.arm64"
    
    # Install the runner scale set with version
    echo "Installing/upgrading runner scale set version ${CHART_VERSION}..."
    helm upgrade --install ${RUNNER_NAME} \
      --namespace ${RUNNER_NAMESPACE} \
      -f "$TEMP_RUNNER_VALUES" \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set --version=${CHART_VERSION}
    
    # Clean up temp files
    rm "$TEMP_CONTROLLER_VALUES" "$TEMP_RUNNER_VALUES"
    
    echo -e "${GREEN}GitHub Runners deployment complete.${NC}"
    echo "You can check the status of your runners with:"
    echo "kubectl get pods -n ${RUNNER_NAMESPACE}"
    echo "kubectl logs -n ${RUNNER_NAMESPACE} ${RUNNER_NAME}-*-listener"
}

# Function to destroy the GKE cluster
destroy_cluster() {
    echo -e "${YELLOW}Destroying GKE cluster '${CLUSTER_NAME}' in project ${GKE_PROJECT_ID}, region ${GKE_REGION}...${NC}"
    gcloud container clusters delete "$CLUSTER_NAME" --region="$GKE_REGION" --project="$GKE_PROJECT_ID" --quiet
    echo -e "${GREEN}GKE cluster '${CLUSTER_NAME}' destroyed successfully.${NC}"
}

# Main script execution
if [ $# -lt 1 ]; then
    usage
fi

COMMAND=$1
shift

parse_args "$@"

case $COMMAND in
    create)
        check_prerequisites
        check_required_files
        check_gcp_project
        create_cluster
        deploy_runners
        ;;
    destroy)
        check_gcp_project
        destroy_cluster
        ;;
    deploy)
        check_prerequisites
        check_required_files
        check_gcp_project
        deploy_runners
        ;;
    clean)
        check_prerequisites
        check_gcp_project
        cleanup_old_crds
        ;;
    *)
        usage
        ;;
esac

exit 0