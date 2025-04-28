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
RUNNER_NAMESPACE="actions-runner-system"
# Set these variables for your specific use case
GITHUB_OWNER=""
GITHUB_REPO=""
RUNNER_NAME=""
# Directory for runner YAML files
MANIFESTS_DIR="./runner-manifests"
# Kind cluster configuration in root directory
KIND_CONFIG="./kind-cluster.yaml"
# Token secret file path
TOKEN_SECRET_FILE="$MANIFESTS_DIR/github-token-secret.yaml"

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
    echo ""
    echo "Options:"
    echo "  --token=<token>       GitHub Personal Access Token (required for create/deploy)"
    echo "  --owner=<org/user>    GitHub organization or username"
    echo "  --repo=<repo>         GitHub repository name (if empty, runners will be org-level)"
    echo "  --name=<name>         Name for runner (required for variable substitution in manifests)"
    echo ""
    echo "Examples:"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --repo=myrepo --name=myrunner"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --name=myrunner"
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
    
    # Check runner manifests directory
    if [ ! -d "$MANIFESTS_DIR" ]; then
        echo -e "${RED}Error: Runner manifests directory $MANIFESTS_DIR does not exist.${NC}"
        echo "Please create it and add your Kubernetes manifests before running this script."
        exit 1
    fi
    
    # Check if there are any yaml files in the manifests directory
    if [ ! "$(ls -A $MANIFESTS_DIR/*.yaml 2>/dev/null)" ]; then
        echo -e "${RED}Error: No YAML files found in $MANIFESTS_DIR${NC}"
        echo "Please add your runner manifests before continuing."
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
apply_with_vars() {
    local file=$1
    echo "Applying $file with variable substitution..."
    
    # Create a temporary file
    TEMP_FILE=$(mktemp)
    
    # Replace variables with their values
    cat "$file" | \
        sed "s|\${GITHUB_TOKEN}|${GITHUB_TOKEN}|g" | \
        sed "s|\${RUNNER_NAME}|${RUNNER_NAME}|g" | \
        sed "s|\${GITHUB_OWNER}|${GITHUB_OWNER}|g" | \
        sed "s|\${GITHUB_REPO}|${GITHUB_REPO}|g" | \
        sed "s|\${RUNNER_NAMESPACE}|${RUNNER_NAMESPACE}|g" > "$TEMP_FILE"
    
    # Apply the updated file
    kubectl apply -f "$TEMP_FILE"
    
    # Remove temporary file
    rm "$TEMP_FILE"
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
    
    echo -e "${YELLOW}Deploying GitHub Actions Runner Controller...${NC}"
    
    # Check if required files exist
    check_required_files
    
    # Install cert-manager (required for actions-runner-controller)
    echo "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.yaml
    
    # Wait for cert-manager to be ready
    echo "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
    
    # Add and update Helm repo
    echo "Adding actions-runner-controller Helm repository..."
    helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
    helm repo update
    
    # Apply namespace first if it exists
    if [ -f "$MANIFESTS_DIR/namespace.yaml" ]; then
        echo "Applying namespace..."
        apply_with_vars "$MANIFESTS_DIR/namespace.yaml"
    fi
    
    # Handle GitHub token secret
    if [ -f "$TOKEN_SECRET_FILE" ]; then
        echo "Applying GitHub token secret with substitution..."
        apply_with_vars "$TOKEN_SECRET_FILE"
    else
        echo "Creating GitHub token secret dynamically..."
        kubectl create namespace ${RUNNER_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
        kubectl create secret generic controller-manager \
            -n ${RUNNER_NAMESPACE} \
            --from-literal=github_token=${GITHUB_TOKEN} \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    # Install the controller
    echo "Installing actions-runner-controller..."
    
    # Check if the helm release already exists
    if helm list -n ${RUNNER_NAMESPACE} | grep -q "actions-runner-controller"; then
        echo "Existing actions-runner-controller release found. Upgrading instead..."
        helm upgrade actions-runner-controller actions-runner-controller/actions-runner-controller \
            --namespace ${RUNNER_NAMESPACE} \
            --set syncPeriod=1m
    else
        helm install actions-runner-controller actions-runner-controller/actions-runner-controller \
            --namespace ${RUNNER_NAMESPACE} \
            --set syncPeriod=1m
    fi
    
    # Wait for controller to be ready
    echo "Waiting for controller to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/actions-runner-controller -n ${RUNNER_NAMESPACE}
    
    # Apply all runner manifests (skipping namespace and token secret which were already applied)
    echo "Applying runner manifests..."
    for manifest in "$MANIFESTS_DIR"/*.yaml; do
        if [[ "$(basename "$manifest")" != "namespace.yaml" && "$(basename "$manifest")" != "github-token-secret.yaml" ]]; then
            apply_with_vars "$manifest"
        fi
    done
    
    echo -e "${GREEN}GitHub Runners deployment complete.${NC}"
    echo "You can check the status of your runners with:"
    echo "kubectl get runners -n ${RUNNER_NAMESPACE}"
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
        deploy_runners
        ;;
    *)
        usage
        ;;
esac

exit 0