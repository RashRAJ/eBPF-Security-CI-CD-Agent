#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
CLUSTER_NAME="github-runners"
GITHUB_TOKEN=""
RUNNER_NAMESPACE="arc-runners"
CONTROLLER_NAMESPACE="arc-systems"
GITHUB_OWNER=""
GITHUB_REPO=""
RUNNER_NAME=""
GKE_REGION="europe-west4"
GKE_PROJECT_ID=""
GKE_NODE_COUNT="2"
GKE_MIN_NODES="1"
GKE_MAX_NODES="3"
GKE_MACHINE_TYPE="e2-standard-4"
GKE_DISK_SIZE="50"
MANIFESTS_DIR="./runner-manifests"
CHART_VERSION="0.10.0"

usage() {
    echo "GitHub Self-Hosted Runner Setup Script for GKE"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  create         Create GKE cluster and deploy GitHub runners"
    echo "  destroy        Destroy GKE cluster"
    echo "  deploy         Deploy GitHub runners to existing cluster"
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
    echo "  $0 destroy --project=my-gcp-project"
    exit 1
}

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
                ;;
        esac
    done
}

check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    if ! command -v gcloud &> /dev/null; then
        echo -e "${RED}Error: gcloud CLI is not installed. Please install gcloud first.${NC}"
        echo "Visit: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl is not installed. Please install kubectl first.${NC}"
        echo "Visit: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}Error: helm is not installed. Please install helm first.${NC}"
        echo "Visit: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    echo -e "${GREEN}All prerequisites are installed.${NC}"
}

check_required_files() {
    if [ ! -f "${MANIFESTS_DIR}/runner-values.yaml" ]; then
        echo -e "${RED}Error: Runner values file not found at ${MANIFESTS_DIR}/runner-values.yaml${NC}"
        exit 1
    fi
    
    if [ ! -f "${MANIFESTS_DIR}/controller-values.yaml" ]; then
        echo -e "${RED}Error: Controller values file not found at ${MANIFESTS_DIR}/controller-values.yaml${NC}"
        exit 1
    fi
}

check_gcp_project() {
    if [ -z "$GKE_PROJECT_ID" ]; then
        echo -e "${RED}Error: GCP Project ID is required. Use --project=<project-id>${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Setting active GCP project to ${GKE_PROJECT_ID}...${NC}"
    gcloud config set project "$GKE_PROJECT_ID"
}

check_resource_usage() {
    echo -e "${YELLOW}Checking quota requirements...${NC}"
    
    local expected_cpus=$((GKE_NODE_COUNT * 4))
    local expected_ssd=$((GKE_NODE_COUNT * GKE_DISK_SIZE))
    
    echo "Resource request - CPUs: ${expected_cpus}, SSD Storage: ${expected_ssd}GB"
    
    if [ $expected_ssd -gt 250 ]; then
        echo -e "${RED}Warning: Your configuration requires ${expected_ssd}GB of SSD storage, but your quota is only 250GB.${NC}"
        echo -e "${RED}Consider reducing disk size or node count.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Resource request is within quota limits.${NC}"
    return 0
}

create_cluster() {
    echo -e "${YELLOW}Checking if cluster '${CLUSTER_NAME}' already exists in project ${GKE_PROJECT_ID}, region ${GKE_REGION}...${NC}"
    
    check_resource_usage || {
        echo -e "${RED}Error: Resource requirements exceed available quota. Aborting cluster creation.${NC}"
        echo "You can request quota increases at: https://console.cloud.google.com/iam-admin/quotas?usage=USED&project=${GKE_PROJECT_ID}"
        exit 1
    }
    
    if gcloud container clusters list --project="$GKE_PROJECT_ID" --region="$GKE_REGION" --filter="name=$CLUSTER_NAME" | grep -q "$CLUSTER_NAME"; then
        echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' already exists.${NC}"
        echo -e "${YELLOW}Using existing cluster.${NC}"
    else
        echo -e "${YELLOW}Creating GKE cluster '${CLUSTER_NAME}'...${NC}"
        
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
            --image-type="UBUNTU_CONTAINERD" \
            --enable-ip-alias \
            --workload-pool="${GKE_PROJECT_ID}.svc.id.goog" \
            --no-enable-master-authorized-networks
        
        echo -e "${GREEN}GKE cluster '${CLUSTER_NAME}' created successfully.${NC}"
    fi
    
    echo -e "${YELLOW}Getting credentials for cluster...${NC}"
    gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$GKE_REGION" --project="$GKE_PROJECT_ID"
    
    echo -e "${YELLOW}Cluster information:${NC}"
    kubectl cluster-info
}

update_yaml_with_vars() {
    local file=$1
    local dest=$2
    echo "Updating $file with variable substitution to $dest..."
    
    cat "$file" | \
        sed "s|\${GITHUB_TOKEN}|${GITHUB_TOKEN}|g" | \
        sed "s|\${RUNNER_NAME}|${RUNNER_NAME}|g" | \
        sed "s|\${GITHUB_OWNER}|${GITHUB_OWNER}|g" | \
        sed "s|\${GITHUB_REPO}|${GITHUB_REPO}|g" | \
        sed "s|\${RUNNER_NAMESPACE}|${RUNNER_NAMESPACE}|g" > "$dest"
    
    echo "File updated: $dest"
}

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
    
    TEMP_CONTROLLER_VALUES=$(mktemp)
    TEMP_RUNNER_VALUES=$(mktemp)
    
    update_yaml_with_vars "${MANIFESTS_DIR}/controller-values.yaml" "$TEMP_CONTROLLER_VALUES"
    update_yaml_with_vars "${MANIFESTS_DIR}/runner-values.yaml" "$TEMP_RUNNER_VALUES"
    
    echo "Creating controller namespace..."
    kubectl create namespace $CONTROLLER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    
    echo "Creating runner namespace..."
    kubectl create namespace ${RUNNER_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    if helm list -n $CONTROLLER_NAMESPACE | grep -q "arc"; then
        echo "Uninstalling existing controller release..."
        helm uninstall arc -n $CONTROLLER_NAMESPACE
        sleep 10
    fi
    
    echo "Installing/upgrading gha-runner-scale-set-controller version ${CHART_VERSION}..."
    helm upgrade --install arc \
      --namespace $CONTROLLER_NAMESPACE \
      -f "$TEMP_CONTROLLER_VALUES" \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller --version=${CHART_VERSION}
    
    echo "Waiting for controller to be ready..."
    sleep 20
    
    MAX_ATTEMPTS=3
    ATTEMPT=1
    CONTROLLER_READY=false
    
    while [ $ATTEMPT -le $MAX_ATTEMPTS ] && [ "$CONTROLLER_READY" = "false" ]; do
        echo "Attempt $ATTEMPT/$MAX_ATTEMPTS: Checking controller deployment..."
        
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
    
    if helm list -n $RUNNER_NAMESPACE | grep -q "$RUNNER_NAME"; then
        echo "Uninstalling existing runner scale set release..."
        helm uninstall $RUNNER_NAME -n $RUNNER_NAMESPACE
        sleep 10
    fi
    
    echo "Installing/upgrading runner scale set version ${CHART_VERSION}..."
    helm upgrade --install ${RUNNER_NAME} \
      --namespace ${RUNNER_NAMESPACE} \
      -f "$TEMP_RUNNER_VALUES" \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set --version=${CHART_VERSION}
    
    rm "$TEMP_CONTROLLER_VALUES" "$TEMP_RUNNER_VALUES"
    
    echo -e "${GREEN}GitHub Runners deployment complete.${NC}"
    echo "You can check the status of your runners with:"
    echo "kubectl get pods -n ${RUNNER_NAMESPACE}"
    echo "kubectl logs -n ${RUNNER_NAMESPACE} ${RUNNER_NAME}-*-listener"
}

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
    *)
        usage
        ;;
esac

exit 0