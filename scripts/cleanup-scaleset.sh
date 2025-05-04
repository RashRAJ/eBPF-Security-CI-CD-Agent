# Delete all runner scale sets in the namespace
kubectl delete runnerscalesets --all -n arc-runners

# Or uninstall all helm releases in the namespace
helm list -n arc-runners -q | xargs -I {} helm uninstall {} -n arc-runners