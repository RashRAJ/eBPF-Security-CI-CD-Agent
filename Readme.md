# Usage Instructions

## Deployment

```sh
# Deploy
chmod +x setup.sh
./setup.sh create --token=TOKEN --owner=rashraj --repo=eBPF-Security-CI-CD-Agent --name=ebpf-runners-cicd

# Troubleshoot
kubectl get ephemeralrunners -n arc-runners
kubectl get pods -n arc-runners
kubectl get pods -n arc-runners --field-selector=status.phase!=Running
kubectl logs -n arc-systems deployment/arc-gha-rs-controller 
kubectl logs -n arc-systems ebpf-runners-cicd-754b578d-listener
kubectl describe pod ebpf-runners-cicd-d65k6-runner-dmjsl -n arc-runners
kubectl describe nodes github-runners-control-plane

# cleanup
./setup.sh clean
./setup.sh destroy
```

## References

- https://github.com/actions/actions-runner-controller
- https://github.com/actions/actions-runner-controller/tree/master/charts/gha-runner-scale-set
- https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/deploying-runner-scale-sets-with-actions-runner-controller
- https://github.com/kondukto-io/kntrl
