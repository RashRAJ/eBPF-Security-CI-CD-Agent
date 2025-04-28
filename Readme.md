# Usage Instructions

The ultimate goal is likely to demonstrate the effectiveness of the kntrl eBPF-based agent in identifying and potentially preventing malicious behavior during CI/CD pipeline execution. The use of a dedicated ebpf-runners-cicd runner highlights the need for specific kernel capabilities for this type of monitoring

In summary, this pipeline aims to:

* Establish a baseline: The build job runs a seemingly normal setup while the kntrl agent monitors system activity in the background.
* Simulate a threat: The malicious-build job intentionally performs actions that could be indicative of a compromised build environment.
* Verify security monitoring: The final step in the malicious-build job attempts to confirm if the kntrl agent (from the build job) was able to detect these suspicious activities.

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
helm delete ebpf-runners-cicd -n arc-runners --no-hooks

# cleanup
./setup.sh clean
./setup.sh destroy
```

## References

- https://github.com/actions/actions-runner-controller
- https://github.com/actions/actions-runner-controller/tree/master/charts/gha-runner-scale-set
- https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/deploying-runner-scale-sets-with-actions-runner-controller
- https://github.com/kondukto-io/kntrl
