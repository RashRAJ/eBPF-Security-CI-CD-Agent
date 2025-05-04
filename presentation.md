# Securing CI/CD Pipelines with eBPF

## 1. CI/CD Agents Overview

### Types of CI/CD Agents

**Managed Runners**: GitHub Actions, GitLab CI (provided by platform)
**Self-Hosted Runners**: Custom infrastructure you control - For Enterprise Users(Audience)
 - GitHub Self-Hosted Runners
 - GitLab Runners
 - Jenkins Agents

## 2. Environment Requirements

### Machine Specifications

- **CPU**: 4 vCPUs (e.g., e2-standard-4 on GKE)
- **Memory**: 16GB RAM
- **OS**: Ubuntu 22.04 LTS
- **Architecture**: x86_64/AMD64

**NOTE**: Any deviation from this machine specifications has not yet been tested to be fully working such as Ubuntu 22 or other linux distro or ARM64 architecture instruction set.

### Required System Access

- Privileged containers
- Kernel capabilities:
 - `SYS_ADMIN`
 - `SYS_PTRACE`
 - `IPC_LOCK`
 - `NET_ADMIN`
 - `SYS_RESOURCE`

## 3. eBPF Prerequisites

### Kernel Requirements

- Linux kernel with eBPF support
- Access to critical filesystems:
 - `/sys/fs/bpf`
 - `/sys/fs/cgroup`
 - `/lib/modules`
 - `/sys/kernel/debug`
 - `/sys/kernel/tracing`

### Permissions

- `kernel.unprivileged_bpf_disabled=0`
- Sufficient memory lock limits
- Access to BPF syscalls

## 4. Why eBPF for CI/CD Security?

### Key Benefits

- **Automatic Security Monitoring**: All workflows protected by default
- **Network Traffic Control**: Real-time monitoring and enforcement
- **Zero Configuration**: No changes to existing pipelines
- **Deep Visibility**: Kernel-level insights without performance impact

### Security Features

- ✅ Monitor all network connections
- ✅ Block unauthorized destinations
- ✅ Detect secret leakage attempts
- ✅ Log security events
- ✅ Allow approved connections only

### Real Examples

- **Allowed**: `download.kondukto.io` (build dependencies)
- **Blocked**: `webhook.site` (potential data exfiltration)

## 5. Deployment Architectures

### Option 1: Sidecar Container (Recommended)

**Advantages:**

With our eBPF sidecar implementation:

- ✅ Automatic security for all CI/CD jobs
- ✅ Real-time network monitoring
- ✅ Blocked malicious connections
- ✅ Zero configuration overhead
- ✅ Detailed security reports

### Option 2: In-Pipeline Execution

**Advantages:**

- Simple setup
- No infrastructure changes

**Disadvantages:**

- Repeated initialization
- Slower pipeline execution
- Configuration in every workflow

### Option 3: Baked into Runner Image

**Advantages:**

- Fastest startup
- Consistent across all runners
- Single maintenance point

**Disadvantages:**

- Requires custom image management
- More complex updates

### Sidecar Architecture Benefits

**Why Choose Sidecar?**

**Automatic Protection**
- Starts with every runner pod
- No manual intervention needed

**Simplified Pipelines**
- Remove security setup from workflows
- Focus on actual CI/CD tasks

**Consistent Security**
- Same protection for all jobs
- Centralized configuration

**Scalability**
- Handles multiple concurrent jobs
- Efficient resource utilization

**Implementation Benefits**
- Zero Changes to existing pipelines
- Immediate Protection for all workflows
- Centralized Logging and monitoring
- Easy Updates without modifying pipelines

## 6. Security Report Intelligence

### Making Sense of the Security Report

**Report Components**

- **Connection Events**: Each attempt to establish network connection
- **Allowed/Blocked Status**: Enforcement decisions based on security policy
- **IP Addresses**: Source and destination for each connection
- **Timestamps**: When each event occurred
- **Process Information**: Which process initiated the connection

**Key Metrics to Monitor**

- Total connection attempts
- Blocked vs allowed ratio
- Unique destinations contacted
- Potential data exfiltration attempts
- Unauthorized service access

**Interpreting Results**

- **High block rate**: May indicate attempted attacks or misconfigured policies
- **Unexpected destinations**: Could signal compromised dependencies
- **Repeated attempts**: Might indicate persistence mechanisms
- **Known malicious IPs**: Immediate security concern requiring investigation

## 7. [Deploying Policies](./opa-policies/policy-deployment.md)

Benefits of OPA-based Policies

1. Declarative Security: Define what's allowed/blocked in clear rules
2. Dynamic Updates: Change policies without redeploying runners
3. Complex Logic: Create sophisticated rules based on multiple factors
4. Centralized Management: Manage all policies in one place
5. Version Control: Track policy changes in Git
6. Testing: Test policies before deployment
7. Reusability: Share policies across different environments

This approach makes your CI/CD security policies much more maintainable and scalable compared to hardcoding allowed/blocked hosts in the kntrl command line.
