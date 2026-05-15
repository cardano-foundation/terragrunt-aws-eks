# EKS Hybrid Nodes Support

This repository supports EC2 instances in different VPCs joining EKS clusters as worker nodes using the `nodeadm` CLI tool and standard EC2 instance profiles.

## Overview

These "hybrid nodes" are EC2 instances managed by autoscaling groups that:
- Run in VPCs different from the EKS control plane VPC
- Use VPC peering to communicate with the control plane
- Join the EKS cluster directly using `apiServerEndpoint` and `certificateAuthority`
- Use the `nodeadm` CLI tool for installation and initialization
- Use standard EC2 IAM instance profiles for authentication (no SSM Hybrid Activation needed)
- Are managed via AWS SSM for optional configuration (swap, kubelet settings, etc.)
- Support all the same features as managed node groups

**Note**: This implementation is optimized for EC2 instances in AWS. For true on-premises or edge hybrid nodes, AWS SSM Hybrid Activations would be required.

## Architecture

```
┌─────────────────────────────┐         ┌─────────────────────────────┐
│  Control Plane VPC          │         │  Hybrid Node VPC            │
│  (172.1.0.0/16)             │◄────────┤  (172.2.0.0/16)             │
│                             │ Peering │                             │
│  ┌─────────────────────┐    │         │  ┌─────────────────────┐    │
│  │ EKS Control Plane   │    │         │  │ Hybrid Node ASG     │    │
│  │ - API Server        │    │         │  │ - EC2 Instances     │    │
│  │ - etcd             │    │         │  │ - Instance Profile  │    │
│  └─────────────────────┘    │         │  │ - nodeadm CLI       │    │
│                             │         │  └─────────────────────┘    │
│  ┌─────────────────────┐    │         │                             │
│  │ Managed Node Groups │    │         │                             │
│  └─────────────────────┘    │         │                             │
└─────────────────────────────┘         └─────────────────────────────┘
```

## Configuration

### 1. Define Multiple VPCs

In `config.yaml`, define your VPCs including the hybrid node VPC:

```yaml
network:
  vpc:
    regions:
      eu-west-1:
        example-com:
          ipv4-cidr: 172.1.0.0/16
          subnets:
            default:
              ipv4-cidr: 172.1.0.0/18
              private_subnets_enabled: true
              public_subnets_enabled: true
              igw: true
              ngw: true
              availability-zones:
                - eu-west-1a
                - eu-west-1b
                - eu-west-1c
        
        # Additional VPC for hybrid nodes
        hybrid-vpc:
          ipv4-cidr: 172.2.0.0/16
          subnets:
            default:
              ipv4-cidr: 172.2.0.0/18
              private_subnets_enabled: true
              public_subnets_enabled: true
              igw: true
              ngw: true
              availability-zones:
                - eu-west-1a
                - eu-west-1b
                - eu-west-1c
          # Configure VPC peering to control plane VPC
          peering:
            to-control-plane:
              peer-vpc: example-com
```

### 2. Configure Hybrid Node Groups

Add `hybrid-node-groups` to your EKS cluster definition:

```yaml
eks:
  regions:
    eu-west-1:
      cluster-name-0:
        network:
          vpc: example-com  # Control plane VPC
        node-groups:
          # Regular managed node groups...
        
        # Hybrid node groups in different VPC
        hybrid-node-groups:
          hybrid-compute:
            network:
              vpc: hybrid-vpc  # Different VPC!
              region: eu-west-2  # Optional: deploy in different region
              subnet:
                name: default
                kind: private
              availability-zones:
                - a
                - b
            desired-size: 2
            min-size: 1
            max-size: 5
            instance-types:
              - t3a.large
            ami-type: amazon-linux-2/recommended  # or amazon-linux-2023/recommended
            autoscaler-enabled: true
            spot-enabled: false
            block-device-mappings:
              xvda:
                volume-size: 50
                volume-type: gp3
                encrypted: true
                delete-on-termination: true
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
            swap:
              enabled: true
              size: 4  # GB
              behavior: LimitedSwap
```

## Configuration Options

### Required Fields

- `network.vpc`: The VPC name where hybrid nodes will be created
- `network.subnet.name`: Subnet name to use
- `network.subnet.kind`: Either `public` or `private`
- `instance-types`: Array of EC2 instance types

### Optional Fields

- `network.region`: AWS region for the hybrid nodes (default: cluster region). **This enables cross-region hybrid nodes!**
- `network.availability-zones`: Specific AZs to use (default: all AZs in subnet)
- `desired-size`: Initial number of nodes (default: 1)
- `min-size`: Minimum nodes (default: 1)
- `max-size`: Maximum nodes (default: 3)
- `ami-type`: AMI type path (default: `amazon-linux-2/recommended`)
  - Options: `amazon-linux-2/recommended`, `amazon-linux-2023/recommended`
- `autoscaler-enabled`: Enable cluster autoscaler (default: false)
- `spot-enabled`: Use spot instances (default: false)
- `spot-max-price`: Max spot price (empty = on-demand price)
- `max-pods`: Maximum pods per node (optional)
- `block-device-mappings`: EBS volume configuration
- `exposed-ports`: Security group ingress rules
- `extra-iam-policies`: Additional IAM policies to attach
- `swap`: Swap configuration
  - `enabled`: Enable/disable swap
  - `size`: Swap size in GB
  - `behavior`: `LimitedSwap` or `NoSwap`

## How It Works

### 1. VPC Peering

The VPC module automatically creates:
- VPC peering connections between VPCs with `peering` configuration
- Route table entries in both VPCs for the peered CIDR blocks
- Accepts the peering connection automatically

### 2. Hybrid Node Provisioning

For each hybrid node group, the EKS module creates:

**IAM Resources:**
- IAM role with assume role policy for EC2 service
- Policy attachments for: EKS Worker Node, CNI, ECR, SSM, ALB
- IAM instance profile

**Security Groups:**
- Security group for hybrid nodes
- Ingress rules for kubelet (10250), HTTPS (443), and inter-node communication
- Egress rule for all traffic
- Bidirectional rules between control plane and hybrid nodes
- Custom exposed port rules

**Autoscaling Group:**
- CloudPosse EC2 autoscaling group module (v0.40.0)
- Launch template with:
  - Latest EKS-optimized AMI for specified version and type
  - User data script using nodeadm for cluster join
  - Block device mappings
  - Security groups
  - IAM instance profile

**SSM Associations:**
- Optional swap configuration via SSM Run Command
- Targets instances by ASG tags

### 3. Cluster Join Process

Hybrid nodes join the cluster using nodeadm with direct API server connection:

```bash
#!/bin/bash
set -ex

# Get cluster information
CLUSTER_NAME=<cluster-name>
API_SERVER_ENDPOINT=<api-server-endpoint>
CERT_AUTHORITY=<base64-encoded-ca>
CLUSTER_CIDR=<service-ipv4-cidr>
EKS_CLUSTER_VERSION=<version>

# Create NodeConfig
cat <<EOF > /tmp/nodeconfig.yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: $CLUSTER_NAME
    apiServerEndpoint: $API_SERVER_ENDPOINT
    certificateAuthority: $CERT_AUTHORITY
    cidr: $CLUSTER_CIDR
EOF

# Install nodeadm CLI
curl -o /tmp/nodeadm.tar.gz "https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm.tar.gz"
tar -xzf /tmp/nodeadm.tar.gz -C /usr/local/bin/
chmod +x /usr/local/bin/nodeadm

# Install EKS dependencies
nodeadm install $EKS_CLUSTER_VERSION

# Initialize the node
nodeadm init -c file:///tmp/nodeconfig.yaml
```

The nodeadm process:
1. Installs containerd, kubelet, and required dependencies
2. Configures kubelet with cluster connection details from NodeConfig
3. Uses EC2 instance profile for IAM authentication
4. Joins node to the cluster via API server endpoint
5. Node appears in cluster and is ready for scheduling

### 4. SSM Configuration

The implementation uses:
- **EC2 Instance Profile**: Standard IAM authentication for EC2 instances
- **SSM Associations**: Optional post-bootstrap configuration for swap and other settings
- **nodeadm CLI**: Official EKS tool for node management

### 5. Remote Network Configuration (Optional)

For true on-premises or edge hybrid nodes (not EC2), you would need to configure:
- **remoteNodeNetworks**: CIDR ranges for nodes outside AWS
- **remotePodNetworks**: CIDR ranges for pods on remote nodes

These are cluster-level settings that tell EKS how to route traffic to/from on-premises infrastructure. For EC2 instances in AWS VPCs, VPC peering handles the routing automatically.

## Security

### Network Security

- **VPC Peering**: Isolated network communication between VPCs
- **Security Groups**: 
  - Control plane ↔ Hybrid nodes: ports 443, 10250
  - Hybrid nodes ↔ Hybrid nodes: all ports
  - Custom exposed ports as configured

### IAM Security

Hybrid nodes have the minimum required permissions:
- `AmazonEKSWorkerNodePolicy`: Join cluster and report status
- `AmazonEKS_CNI_Policy`: Configure pod networking
- `AmazonEC2ContainerRegistryReadOnly`: Pull container images
- `AmazonSSMManagedInstanceCore`: SSM management
- Custom policies as configured

### Best Practices

1. **Use Private Subnets**: Deploy hybrid nodes in private subnets with NAT gateway
2. **Encrypt EBS Volumes**: Set `encrypted: true` in block device mappings
3. **Limit CIDR Blocks**: Restrict `exposed-ports` to specific IP ranges
4. **Enable SSM**: Provides secure shell access without SSH keys
5. **Use Spot Instances Carefully**: Only for fault-tolerant workloads

## Monitoring and Operations

### View Hybrid Nodes

```bash
kubectl get nodes -l node.kubernetes.io/instance-type
```

### Check Node Status

```bash
kubectl describe node <node-name>
```

### SSM Session

Connect to a hybrid node:

```bash
aws ssm start-session --target <instance-id>
```

### View Logs

Check bootstrap logs:

```bash
# Via SSM
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/cloud-init-output.log

# Via CloudWatch (if configured)
aws logs tail /aws/eks/<cluster-name>/hybrid-nodes
```

## Troubleshooting

### Nodes Not Joining Cluster

1. Check VPC peering status
2. Verify security group rules allow traffic
3. Check bootstrap logs: `/var/log/cloud-init-output.log`
4. Verify IAM role has correct policies
5. Check cluster endpoint accessibility

### Network Issues

1. Verify route tables have peering routes
2. Check security group rules
3. Test connectivity: `telnet <cluster-endpoint> 443`

### SSM Associations Not Running

1. Verify SSM agent is running: `systemctl status amazon-ssm-agent`
2. Check IAM role has `AmazonSSMManagedInstanceCore`
3. View association status in SSM console

## Outputs

The implementation provides these outputs:

### VPC Module

```hcl
output "vpc_peering_connections" {
  # Map of peering connection IDs and statuses
}
```

### EKS Module

```hcl
output "hybrid_node_groups" {
  # Map with:
  # - asg_name: Autoscaling group name
  # - asg_id: Autoscaling group ID
  # - iam_role_arn: IAM role ARN
  # - iam_role_name: IAM role name
  # - security_group_id: Security group ID
}
```

## Limitations

1. **Same Region Only**: VPC peering only works within the same AWS region
2. **CIDR Overlap**: VPCs must have non-overlapping CIDR blocks
3. **AMI Support**: Only EKS-optimized AMIs (AL2 and AL2023) are supported
4. **Manual Peering Acceptance**: For cross-account peering, manual acceptance is required

## Migration from Managed Node Groups

To migrate from managed node groups to hybrid nodes:

1. Add hybrid node group configuration
2. Apply infrastructure changes
3. Cordon and drain managed node group nodes
4. Remove managed node group configuration
5. Apply infrastructure changes again

## Cost Considerations

Hybrid nodes can reduce costs by:
- Using spot instances (`spot-enabled: true`)
- Deploying in regions with lower EC2 pricing
- Using reserved instances for stable workloads
- Rightsizing with appropriate instance types

## Examples

See `environments/dev-example/config.yaml` for a complete working example.

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review CloudWatch logs
3. Check AWS Systems Manager Run Command history
4. Open an issue in the repository
