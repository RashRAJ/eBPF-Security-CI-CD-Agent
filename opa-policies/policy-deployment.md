# Policy deployment

## Directory Structure for Policies

policy-chart/
├── Chart.yaml
├── values.yaml
├── templates/
│   └── configmap.yaml
└── policies/
    ├── allowed_domains.rego
    ├── blocked_domains.rego
    ├── secret_detection.rego
    ├── business_hours.rego
    └── environment_policy.rego


## Dynamic Policy Updates
Use Kubernetes ConfigMap reloading:

# Add to sidecar container
- name: kntrl-sidecar
  # ... other config ...
  volumeMounts:
    - name: kntrl-policies
      mountPath: /policies
  # Add a sidecar process to watch for config changes
  lifecycle:
    postStart:
      exec:
        command:
        - /bin/sh
        - -c
        - |
          while true; do
            inotifywait -e modify,create,delete /policies/
            pkill -HUP kntrl
            sleep 5
          done &