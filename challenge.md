# Gitlab Google CI/CD

## Agenda

## Partner Interest

The goal is not to do what we like, the goal is to showcase partner technologies and how
customers discover and use more capabilities of their products/services

## Goal

- Securing Pipeline artifacts against various attack vectors
- Intelligent pipeline runs analytics

## Techniology Matrix

Step1a: Gitlab Self-hosted runner on GKE with eBPF security controls baked into the runner.
Step1b: Gitlab SaaS runners with eBPF security controls baked into the pipeline *templates*.
        Contribute to gutlab [secrity templates](https://gitlab.com/gitlab-org/gitlab/-/tree/master/lib/gitlab/ci/templates/Security) our solution
Step2: Gemimi Models for On-demand Intelligence on pipeline run scan reports
Step3: Fan-In Aggegate all pipeline run reports into Big query to Retrain model on-schedule using Vertext AI and Vertext Model garden
Step 4(Optionally): Vertext AI - Real-time analytics on pipeline reports (fine-tunning the model on on-going pipeline run reports)

## Research/TODO

- What other Gitlab products and services can we enable/showcase?
- What other Google products and services can we enable/showase?

## Impleemntation steps

- Architecture/flow of the solution
- Runner Setup with eBPF controls
- eBPF Controls and policies (using kntrl or custom build?)
- Genimi integration on Gitlab Pipeline
