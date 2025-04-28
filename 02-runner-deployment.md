# Deployment Steps

## Add the Helm repository:
```bash
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
helm repo update
```

## Install the controller:
```bash
helm install actions-runner-controller actions-runner-controller/actions-runner-controller \
  --namespace actions-runner-system \
  --create-namespace
```

## Create a GitHub Personal Access Token (PAT) with appropriate permissions:


For organization runners: `admin:org` permission
For repository runners: `repo` permission



