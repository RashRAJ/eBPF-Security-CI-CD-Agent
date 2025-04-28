## Usage Instructions

Make the script executable:
```chmod +x setup.sh```


Create a cluster with GitHub runners:

For organization runners
```
./setup.sh create --token=ghp_your_token --owner=your-org-name --replicas=2
```

For repository runners
```
./setup.sh create --token=ghp_your_token --owner=your-org-name --repo=your-repo-name
```
Destroy the cluster:
```
bash./setup.sh destroy
```

Deploy runners to an existing cluster:
```
./setup.sh deploy --token=ghp_your_token --owner=your-org-name
```

./setup.sh clean

...

You can now run the script with a custom runner name:
bash./setup.sh create --token=ghp_your_token --owner=rashraj --repo=eBPF-Security-CI-CD-Agent --name=ebpf-runners
Or let the script automatically create a valid name:
bash./setup.sh create --token=ghp_your_token --owner=rashraj --repo=eBPF-Security-CI-CD