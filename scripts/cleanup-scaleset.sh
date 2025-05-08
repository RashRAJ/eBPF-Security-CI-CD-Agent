# Delete all runner scale sets in the namespace
kubectl delete runnerscalesets --all -n arc-runners

# Or uninstall all helm releases in the namespace
helm list -n arc-runners -q | xargs -I {} helm uninstall {} -n arc-runners

kubectl delete runnerscaleset ebpf-runners -n arc-runners
kubectl delete runnerscaleset epbfrunner -n arc-runners
kubectl delete runnerscaleset ebpfrunnerjumbo -n arc-runners
kubectl delete runnerscaleset epbfrunner2 -n arc-runners
kubectl delete runnerscaleset ebpf-runners-cicd -n arc-runners
kubectl delete runnerscaleset ebpfrunnerhr -n arc-runners