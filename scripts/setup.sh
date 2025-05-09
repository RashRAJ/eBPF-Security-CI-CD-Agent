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
# Directory for runner YAML files
MANIFESTS_DIR="./runner-manifests"
# Kind cluster configuration in root directory
KIND_CONFIG="./kind-cluster.yaml"
# Chart version - set to 0.10.0 to avoid YAML parsing errors
CHART_VERSION="0.10.0"

# Function to display usage information
usage() {
    echo "GitHub Self-Hosted Runner Setup Script"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  create         Create Kind cluster and deploy GitHub runners"
    echo "  destroy        Destroy Kind cluster"
    echo "  deploy         Deploy GitHub runners to existing cluster"
    echo "  clean          Remove old CRDs from the cluster"
    echo ""
    echo "Options:"
    echo "  --token=<token>       GitHub Personal Access Token (required for create/deploy)"
    echo "  --owner=<org/user>    GitHub organization or username"
    echo "  --repo=<repo>         GitHub repository name (if empty, runners will be org-level)"
    echo "  --name=<name>         Name for runner (required for variable substitution in manifests)"
    echo "  --version=<version>   Chart version to use (default: ${CHART_VERSION})"
    echo ""
    echo "Examples:"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --repo=myrepo --name=myrunner"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --name=myrunner --version=0.10.0"
    echo "  $0 clean"
    echo "  $0 destroy"
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
            *)
                # Unknown option
                ;;
        esac
    done
}

# Function to check required tools
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check for kind
    if ! command -v kind &> /dev/null; then
        echo -e "${RED}Error: kind is not installed. Please install kind first.${NC}"
        echo "Visit: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
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
    # Check kind cluster config
    if [ ! -f "$KIND_CONFIG" ]; then
        echo -e "${RED}Error: Kind cluster configuration not found at $KIND_CONFIG${NC}"
        exit 1
    fi
    
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

# Function to create the Kind cluster
create_cluster() {
    echo -e "${YELLOW}Checking if cluster '${CLUSTER_NAME}' already exists...${NC}"
    
    # Check if cluster already exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' already exists.${NC}"
        echo -e "${YELLOW}Using existing cluster.${NC}"
    else
        echo -e "${YELLOW}Creating Kind cluster '${CLUSTER_NAME}'...${NC}"
        kind create cluster --config "$KIND_CONFIG"
        echo -e "${GREEN}Kind cluster '${CLUSTER_NAME}' created successfully.${NC}"
    fi
    
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
    
    # Install cert-manager (required for actions-runner-controller)
    echo "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.yaml
    
    # Wait for cert-manager to be ready
    echo "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
    
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
    
    # Install the controller using the official OCI chart with version
    echo "Installing/upgrading gha-runner-scale-set-controller version ${CHART_VERSION}..."
    helm upgrade --install arc \
      --namespace $CONTROLLER_NAMESPACE \
      -f "$TEMP_CONTROLLER_VALUES" \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller --version=${CHART_VERSION}
    
    # Wait for controller to be ready with correct deployment name
    echo "Waiting for controller to be ready..."
    # Give some time for the deployment to be created
    sleep 10
    kubectl wait --for=condition=available --timeout=300s deployment/arc-gha-rs-controller -n $CONTROLLER_NAMESPACE
    
    # Check if runner scale set is already installed and uninstall it first
    if helm list -n $RUNNER_NAMESPACE | grep -q "$RUNNER_NAME"; then
        echo "Uninstalling existing runner scale set release..."
        helm uninstall $RUNNER_NAME -n $RUNNER_NAMESPACE
        # Wait a bit for resources to be cleaned up
        sleep 10
    fi
    
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

# Function to destroy the Kind cluster
destroy_cluster() {
    echo -e "${YELLOW}Destroying Kind cluster '${CLUSTER_NAME}'...${NC}"
    kind delete cluster --name ${CLUSTER_NAME}
    echo -e "${GREEN}Kind cluster '${CLUSTER_NAME}' destroyed successfully.${NC}"
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
        create_cluster
        deploy_runners
        ;;
    destroy)
        destroy_cluster
        ;;
    deploy)
        check_prerequisites
        check_required_files
        deploy_runners
        ;;
    clean)
        check_prerequisites
        cleanup_old_crds
        ;;
    *)
        usage
        ;;
esac

exit 0