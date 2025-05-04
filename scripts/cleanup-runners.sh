#!/bin/bash

# Configuration
GITHUB_TOKEN=""
OWNER="rashraj"
REPO="eBPF-Security-CI-CD-Agent"

# First, get all runners
echo "Fetching all runners..."
runners_json=$(curl -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$OWNER/$REPO/actions/runners")

# Extract runner IDs and names
runner_ids=$(echo $runners_json | jq -r '.runners[].id')
runner_names=$(echo $runners_json | jq -r '.runners[].name')

# Convert to arrays
IFS=$'\n' read -rd '' -a ids_array <<<"$runner_ids"
IFS=$'\n' read -rd '' -a names_array <<<"$runner_names"

# Delete each runner
for i in "${!ids_array[@]}"; do
    runner_id="${ids_array[$i]}"
    runner_name="${names_array[$i]}"
    
    echo "Deleting runner: $runner_name (ID: $runner_id)"
    
    curl -L \
      -X DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/$OWNER/$REPO/actions/runners/$runner_id"
    
    echo "Deleted runner: $runner_name"
    echo "-------------------"
done

echo "All runners have been deleted."


# kubectl delete runnerscaleset ebpf-runners -n arc-runners
# kubectl delete runnerscaleset epbfrunner -n arc-runners
# kubectl delete runnerscaleset ebpfrunnerjumbo -n arc-runners
# kubectl delete runnerscaleset epbfrunner2 -n arc-runners
# kubectl delete runnerscaleset ebpf-runners-cicd -n arc-runners
# kubectl delete runnerscaleset ebpfrunnerhr -n arc-runners
