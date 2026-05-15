# EKS Hybrid Nodes Support

This repository supports running EKS hybrid worker nodes on EC2 instances located in VPCs that are different from the EKS control plane VPC, including VPCs in other AWS regions.

The current implementation is based on:
- **AWS Systems Manager Hybrid Activations** for node registration bootstrap
- **EKS hybrid node access entries** (`HYBRID_LINUX`) for cluster access
- **EC2 Auto Scaling Groups** for compute lifecycle management
- **VPC peering** for network connectivity between the EKS control plane VPC and hybrid node VPCs
- **SSM associations** for post-bootstrap node configuration such as swap and kubelet tuning

> **Important:** This implementation does **not** currently use the direct `nodeadm init` flow described in older versions of this document. The Terraform in `tg-modules/eks/terragrunt.hcl` provisions hybrid nodes using SSM activation, EKS hybrid access entries, IAM roles, and Auto Scaling Groups.

## Overview

These hybrid node groups are EC2 instances managed by autoscaling groups that:
- Run in VPCs different from the EKS control plane VPC
- Can run in other AWS regions
- Connect to the cluster over routed VPC-to-VPC connectivity
- Register through AWS SSM Hybrid Activation
- Are granted cluster access using `aws_eks_access_entry` with type `HYBRID_LINUX`
- Use standard EC2 IAM instance profiles for AWS permissions on the instance
- Can receive optional SSM-based post-bootstrap configuration such as swap configuration
- Can be exposed to the cluster autoscaler through the expected ASG tags

## Architecture

```text
┌─────────────────────────────┐              ┌─────────────────────────────┐
│  Control Plane VPC          │              │  Hybrid Node VPC            │
│  eu-west-1                  │◄────────────►│  us-east-1 / eu-west-2      │
│  10.128.0.0/16              │   Peering    │  10.130.0.0/16 / 10.129.0.0/16 │
│                             │              │                             │
│  ┌─────────────────────┐    │              │  ┌───────────────────────┐  │
│  │ EKS Control Plane   │    │              │  │ Hybrid Node ASG       │  │
│  │ - API server        │    │              │  │ - EC2 instances       │  │
│  │ - Access entries    │    │              │  │ - IAM instance profile│  │
│  └─────────────────────┘    │              │  │ - SSM activation      │  │
│                             │              │  └───────────────────────┘  │
│  ┌─────────────────────┐    │              │                             │
│  │ Managed Node Groups │    │              │  Optional additional        │
│  │ (same VPC)          │    │              │  hybrid node groups         │
│  └─────────────────────┘    │              │                             │
└─────────────────────────────┘              └─────────────────────────────┘
```

## Configuration

### 1. Define VPCs and Peering

In `config.yaml`, define the control plane VPC and any additional VPCs used for hybrid nodes.

The `environments/dev-example/config.yaml` example currently defines:
- `eu-west-1/example-com` as the control plane VPC
- `eu-west-2/cf-idw` as an additional peered VPC
- `us-east-1/cf-idw` as another peered VPC

Example:

```yaml
network:
  default_region: "eu-west-1"
  default_vpc: "example-com"
  vpc:
    regions:
      eu-west-1:
        example-com:
          ipv4-cidr: 10.128.0.0/16
          subnets:
            default:
              ipv4-cidr: 10.128.0.0/17
              private_subnets_enabled: true
              public_subnets_enabled: true
              igw: true
              ngw: true
              availability-zones:
                - eu-west-1a
                - eu-west-1b
                - eu-west-1c

      us-east-1:
        cf-idw:
          ipv4-cidr: 10.130.0.0/16
          subnets:
            default:
              ipv4-cidr: 10.130.0.0/17
              private_subnets_enabled: true
              public_subnets_enabled: true
              igw: true
              ngw: true
              availability-zones:
                - us-east-1a
                - us-east-1b
                - us-east-1c
          peering:
            to-control-plane:
              peer-vpc: cf-idw
              peer-region: eu-west-1
```

> Note: follow the VPC peering conventions already used in `environments/dev-example/config.yaml` for cross-region connectivity.

### 2. Configure the EKS Cluster

The EKS cluster must define its own VPC and subnets as usual. When `hybrid-node-groups` are present, the module also generates a `remote_network_config` containing the CIDR blocks of the hybrid-node VPCs.

Example:

```yaml
eks:
  regions:
    eu-west-1:
      cluster-name-0:
        k8s-version: 1.30
        network:
          vpc: example-com
          subnets:
            - name: default
              kind: private
            - name: default
              kind: public
```

### 3. Configure Hybrid Node Groups

Add `hybrid-node-groups` beneath the cluster definition.

The current `dev-example` includes:

```yaml
hybrid-node-groups:
  virginia:
    node-kubernetes-io-role: public
    network:
      vpc: cf-idw
      region: us-east-1
      subnet:
        name: default
        kind: private
      availability-zones:
        - b
    instance-types:
      - t3a.large
    desired-size: 1
    min-size: 1
    max-size: 1
    ami-name-filter: "ami-amazon-linux-latest/al2023-ami-minimal-kernel-default-x86_64"
    block-device-mappings:
      xvda:
        volume-size: 20
        volume-type: gp3
        encrypted: true
        delete-on-termination: true
    swap:
      enabled: true
      size: 4
    autoscaler-enabled: false
    cluster-log-retention-period: 7
    exposed-ports:
      traefik-nodeport:
        number: 30443
        protocol: tcp
        cidr-filters:
          - 0.0.0.0/0
    extra-iam-policies:
      enable-ebs-creation: "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      enable-efs-creation: "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
      enable-ssm-access: "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
```

## Configuration Options

### Required Fields

- `network.vpc`: VPC name where the hybrid nodes are created
- `network.region`: AWS region where the hybrid nodes are created
- `network.subnet.name`: subnet name to use
- `network.subnet.kind`: either `public` or `private`
- `instance-types`: list of EC2 instance types

### Common Optional Fields

- `network.availability-zones`: specific AZ suffixes such as `a`, `b`, `c`
- `desired-size`: desired ASG size, default `1`
- `min-size`: minimum ASG size, default `1`
- `max-size`: maximum ASG size, default `3`
- `autoscaler-enabled`: add cluster-autoscaler tags to the ASG
- `spot-enabled`: use EC2 spot instances
- `spot-max-price`: optional max spot price
- `block-device-mappings`: EBS device mapping configuration
- `exposed-ports`: extra ingress rules on the hybrid-node security group
- `extra-iam-policies`: additional IAM policies attached to the hybrid-node EC2 role
- `swap.enabled`: whether swap should be configured or disabled via SSM association
- `swap.size`: swap size in GiB when enabled
- `swap.behavior`: kubelet swap behavior, defaults to `LimitedSwap`
- `node-kubernetes-io-role`: logical node role label to expose on the node

### AMI Setting

The Terraform currently reads the AMI SSM parameter from:
- `ami-ssm-name-filter` (default: `ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`)

Example from Terraform:

```hcl
name = "/aws/service/${ chomp(try("${hng_values.ami-ssm-name-filter}", "ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64")) }"
```

> Note: `environments/dev-example/config.yaml` currently uses `ami-name-filter`, but the Terraform code in `tg-modules/eks/terragrunt.hcl` expects `ami-ssm-name-filter`. If you want a non-default AMI path, use the Terraform-supported key name.

## How It Works

### 1. Cluster Network Configuration

When hybrid node groups are defined, the EKS cluster module adds `remote_network_config` with the CIDR blocks of the hybrid-node VPCs. This allows the control plane to understand remote node network ranges.

The module also adds security group rules allowing traffic from hybrid-node VPC CIDRs into the EKS control plane managed security group.

### 2. VPC Connectivity

Hybrid nodes depend on routed connectivity between the control plane VPC and every hybrid-node VPC. In the repository examples this is achieved with VPC peering and matching route propagation between regions.

### 3. Hybrid Node IAM and Registration

For each hybrid node group, Terraform creates:
- an EC2 IAM role in the hybrid node region
- an IAM instance profile attached to the EC2 instances
- a dedicated EKS hybrid node role module
- `aws_ssm_activation` for registration bootstrap
- `aws_eks_access_entry` with `type = "HYBRID_LINUX"`
- extra IAM policy attachments required for node operation

This means the implementation relies on **SSM hybrid registration plus EKS hybrid access entries**, not a plain `nodeadm`-only bootstrap path.

### 4. Hybrid Node Compute

Each hybrid node group is backed by an EC2 Auto Scaling Group. The ASG:
- launches into the specified subnet(s)
- uses the selected SSM AMI parameter path
- attaches the hybrid node instance profile
- optionally enables spot market options
- optionally adds cluster-autoscaler tags

### 5. Security Groups

For each hybrid node group, the module creates a dedicated security group with:
- all outbound traffic allowed
- optional ingress rules from `exposed-ports`
- broad ingress from the control-plane and hybrid-node VPC CIDR blocks so inter-VPC cluster communication works

### 6. SSM Post-Bootstrap Configuration

The module configures SSM associations for hybrid and standard node groups to perform extra node setup. This currently includes capabilities such as:
- enabling swap
- disabling swap
- adjusting kubelet `max-pods` in some node group flows
- basic bootstrap package installation in standard node groups

### 7. Hybrid Maintenance Manifests

When hybrid node groups are enabled, the module also applies Kubernetes manifests from `./assets/k8s-manifests` using `kubectl_manifest`. These are described in the Terraform as maintenance jobs intended to help keep the cluster healthy around hybrid/CNI-related operations.

## Security

### Network Security

- Hybrid nodes communicate with the control plane over VPC-to-VPC routing
- The EKS managed security group is opened to the CIDR blocks of hybrid-node VPCs
- Each hybrid node group gets its own security group
- Additional public or private application ports can be opened with `exposed-ports`

### IAM Security

Hybrid nodes are granted permissions through a combination of:
- EC2 role attachments in the hybrid-node region
- the EKS hybrid node role module
- EKS access entries for the cluster
- optional additional IAM policies from configuration

By default, the implementation attaches policies including:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryReadOnly`
- `AmazonSSMManagedInstanceCore`
- ALB ingress policy
- any configured extra policies

### Best Practices

1. Use private subnets for hybrid nodes where possible
2. Ensure VPC CIDR ranges do not overlap
3. Keep peering routes symmetric across all participating VPCs
4. Restrict `exposed-ports` to trusted CIDRs
5. Encrypt EBS volumes for hybrid node root disks
6. Validate the correct AMI SSM parameter key is being used

## Monitoring and Operations

### View Nodes

```bash
kubectl get nodes
```

### Check Hybrid Node Labels

```bash
kubectl get nodes --show-labels
```

### Check EKS Access Entries

```bash
aws eks list-access-entries --cluster-name <cluster-name> --region <cluster-region>
```

### Start an SSM Session

```bash
aws ssm start-session --target <instance-id>
```

### Check SSM Activation State

```bash
aws ssm describe-instance-information
```

## Troubleshooting

### Hybrid Nodes Not Registering

1. Verify inter-VPC routing and peering in both directions
2. Verify the hybrid node VPC CIDR is included in the cluster remote network configuration
3. Check that the SSM activation exists and is not expired
4. Confirm the EKS access entry exists with type `HYBRID_LINUX`
5. Confirm the instance profile and IAM role attachments were created successfully
6. Check instance reachability to required AWS APIs and the cluster endpoint

### Networking Problems

1. Verify non-overlapping CIDRs across all VPCs
2. Check route tables in every peered VPC
3. Check the control plane managed security group ingress rule for hybrid VPC CIDRs
4. Check the hybrid node security group ingress rules and any `exposed-ports`

### SSM Issues

1. Verify the instance has `AmazonSSMManagedInstanceCore`
2. Check Systems Manager activation and managed instance status
3. Inspect SSM association execution status in the AWS console
4. Use Session Manager to inspect instance logs and system state

### AMI Issues

1. Verify the configured AMI parameter key exists in the hybrid node region
2. Prefer `ami-ssm-name-filter` in config because that is what Terraform currently reads
3. If using the sample config, reconcile `ami-name-filter` vs `ami-ssm-name-filter`

## Outputs

The implementation currently documents or implies useful outputs/resources around:
- VPC peering connectivity from the VPC module
- EKS cluster resources
- hybrid-node IAM roles, ASGs, and security groups created in Terraform

If you need stable Terraform outputs for hybrid node groups, verify the exact exported outputs in the module being consumed.

## Current Limitations and Caveats

1. **Documentation drift:** older references to `nodeadm`-only bootstrap are outdated
2. **Config key mismatch:** example config uses `ami-name-filter` while Terraform expects `ami-ssm-name-filter`
3. **AWS-focused design:** this implementation is built around AWS VPCs, EC2, SSM, and EKS hybrid-node access entries
4. **Peering complexity increases with each region:** every additional hybrid-node VPC must be routable to the control plane VPC and, in some topologies, to other hybrid-node VPCs as well
5. **SSM activation expiry matters:** the Terraform sets an activation expiration window, so lifecycle handling should be considered for long-running environments

## Dev Example Summary

The current `environments/dev-example/config.yaml` demonstrates:
- a control-plane cluster in `eu-west-1`
- managed node groups in the control-plane VPC
- a hybrid node group named `virginia`
- hybrid infrastructure in `us-east-1`
- supporting VPC definitions in `eu-west-1`, `eu-west-2`, and `us-east-1`
- cross-region peering configuration between those VPCs

## Migration Note

If you are migrating from managed node groups to hybrid node groups in this repository:
1. Add the hybrid node group configuration and required peered VPC definitions
2. Apply infrastructure changes
3. Validate SSM activation, access entry creation, and node registration
4. Drain workloads from the old managed node groups if needed
5. Remove or resize managed node groups
6. Apply again

## Support

For issues or questions:
1. Check the Terraform in `tg-modules/eks/terragrunt.hcl`
2. Compare with `environments/dev-example/config.yaml`
3. Inspect AWS SSM, EKS access entries, and EC2 Auto Scaling resources
4. Open an issue in the repository
