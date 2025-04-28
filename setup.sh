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
RUNNER_REPLICAS=2
# Custom runner name (will default to a sanitized version if not provided)
RUNNER_NAME=""

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
    echo "  --replicas=<num>      Number of runner replicas (default: 2)"
    echo "  --name=<name>         Custom runner name (must be RFC 1123 compliant)"
    echo ""
    echo "Examples:"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --repo=myrepo"
    echo "  $0 create --token=ghp_xxxx --owner=myorg --name=custom-runner"
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
            --replicas=*)
                RUNNER_REPLICAS="${arg#*=}"
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

# Function to create kind cluster config file
create_kind_config() {
    echo -e "${YELLOW}Creating Kind cluster configuration...${NC}"
    cat > kind-cluster.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
    echo -e "${GREEN}Kind cluster configuration created.${NC}"
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
        kind create cluster --config kind-cluster.yaml
        echo -e "${GREEN}Kind cluster '${CLUSTER_NAME}' created successfully.${NC}"
    fi
    
    # Display cluster info
    echo -e "${YELLOW}Cluster information:${NC}"
    kubectl cluster-info
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
    
    echo -e "${YELLOW}Deploying GitHub Actions Runner Controller...${NC}"
    
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
    
    # Create namespace if it doesn't exist
    kubectl create namespace ${RUNNER_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    # Create secret for GitHub token
    echo "Creating GitHub token secret..."
    kubectl create secret generic controller-manager \
        -n ${RUNNER_NAMESPACE} \
        --from-literal=github_token=${GITHUB_TOKEN} \
        --dry-run=client -o yaml | kubectl apply -f -
    
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
    
    # Create runner deployment YAML
    echo "Creating runner deployment..."
    
    # Create a valid Kubernetes name if not provided
    if [ -z "$RUNNER_NAME" ]; then
        if [ -z "$GITHUB_REPO" ]; then
            # For org runners, use org name sanitized
            RUNNER_NAME=$(echo "${GITHUB_OWNER}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' | sed -e 's/^[^a-z0-9]//g' | sed -e 's/[^a-z0-9]$//g')
        else
            # For repo runners, use shorter combination
            # Sanitize repository name (convert to lowercase, replace invalid chars with hyphens)
            SANITIZED_REPO=$(echo "${GITHUB_REPO}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' | sed -e 's/^[^a-z0-9]//g' | sed -e 's/[^a-z0-9]$//g')
            RUNNER_NAME="${GITHUB_OWNER}-${SANITIZED_REPO}"
            
            # Ensure it's not too long (63 chars max for K8s)
            if [ ${#RUNNER_NAME} -gt 50 ]; then
                # If too long, use a hash of the repo name
                HASH=$(echo "${GITHUB_REPO}" | md5sum | cut -c1-8)
                RUNNER_NAME="${GITHUB_OWNER}-${HASH}"
            fi
        fi
    fi
    
    # Ensure runner name is valid (lowercase, starts and ends with alphanumeric)
    RUNNER_NAME=$(echo "${RUNNER_NAME}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' | sed -e 's/^[^a-z0-9]/r-/g' | sed -e 's/[^a-z0-9]$/r/g')
    
    echo "Using runner name: ${RUNNER_NAME}"
    
    if [ -z "$GITHUB_REPO" ]; then
        # Organization level runners
        cat > runner-deployment.yaml << EOF
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: ${RUNNER_NAME}
  namespace: ${RUNNER_NAMESPACE}
spec:
  replicas: ${RUNNER_REPLICAS}
  template:
    spec:
      organization: ${GITHUB_OWNER}
      labels:
        - self-hosted
        - kubernetes
      env:
        - name: GITHUB_URL
          value: https://github.com
        - name: ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER
          value: "false"
        - name: DISABLE_RUNNER_UPDATE
          value: "true"
        - name: RUNNER_FEATURE_FLAG_ONCE
          value: "true"
        - name: NODE_TLS_REJECT_UNAUTHORIZED
          value: "0"
        - name: NODE_OPTIONS
          value: --tls-min-v1.0
        - name: DOCKER_HOST
          value: "unix:///var/run/docker.sock"
      containerMode: kubernetes
      dockerEnabled: true
      dockerdWithinRunnerContainer: true
      ephemeral: false
      workDir: /tmp/runner
      volumeMounts:
        - name: docker-socket
          mountPath: /var/run/docker.sock
      volumes:
        - name: docker-socket
          hostPath:
            path: /var/run/docker.sock
---
apiVersion: actions.summerwind.dev/v1alpha1
kind: HorizontalRunnerAutoscaler
metadata:
  name: ${RUNNER_NAME}-autoscaler
  namespace: ${RUNNER_NAMESPACE}
spec:
  scaleTargetRef:
    name: ${RUNNER_NAME}
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: TotalNumberOfQueuedAndInProgressWorkflowRuns
    scaleUpThreshold: '1'
    scaleDownThreshold: '0'
    scaleUpFactor: '2'
    scaleDownFactor: '0.5'
EOF
    else
        # Repository level runners
        cat > runner-deployment.yaml << EOF
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: ${RUNNER_NAME}
  namespace: ${RUNNER_NAMESPACE}
spec:
  replicas: ${RUNNER_REPLICAS}
  template:
    spec:
      repository: ${GITHUB_OWNER}/${GITHUB_REPO}
      labels:
        - self-hosted
        - kubernetes
      env:
        - name: GITHUB_URL
          value: https://github.com
        - name: ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER
          value: "false"
        - name: DISABLE_RUNNER_UPDATE
          value: "true"
        - name: RUNNER_FEATURE_FLAG_ONCE
          value: "true"
        - name: NODE_TLS_REJECT_UNAUTHORIZED
          value: "0"
        - name: NODE_OPTIONS
          value: --tls-min-v1.0
        - name: DOCKER_HOST
          value: "unix:///var/run/docker.sock"
      containerMode: kubernetes
      dockerEnabled: true
      dockerdWithinRunnerContainer: true
      ephemeral: false
      workDir: /tmp/runner
      volumeMounts:
        - name: docker-socket
          mountPath: /var/run/docker.sock
      volumes:
        - name: docker-socket
          hostPath:
            path: /var/run/docker.sock
---
apiVersion: actions.summerwind.dev/v1alpha1
kind: HorizontalRunnerAutoscaler
metadata:
  name: ${RUNNER_NAME}-autoscaler
  namespace: ${RUNNER_NAMESPACE}
spec:
  scaleTargetRef:
    name: ${RUNNER_NAME}
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: TotalNumberOfQueuedAndInProgressWorkflowRuns
    scaleUpThreshold: '1'
    scaleDownThreshold: '0'
    scaleUpFactor: '2'
    scaleDownFactor: '0.5'
EOF
    fi
    
    # Apply runner deployment
    kubectl apply -f runner-deployment.yaml
    
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
        create_kind_config
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