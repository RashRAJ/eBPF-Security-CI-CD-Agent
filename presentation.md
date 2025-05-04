# Presentation

1. CI/CD Agent: Managed or Self-Hosted(Github/Gitlab, Jenkins) etc
2. Environments Checks (machine type and operating system)
3. eBPF supports in the environment and necceary permisions needed for eBPF program to run on the CI/CD agent
4. What we are using eBPF for?
5. Running mode
  - Sidecar
  - On the pipeline
  - Bake it inside runner image

## Sidecar Mode

Running kntrl as a sidecar container is an excellent idea for scalability and consistency

* Start kntrl automatically with each runner pod:
* Reduce pipeline complexity
* Ensure consistent security monitoring across all jobs
* Avoid repeated kntrl setup in each pipeline
