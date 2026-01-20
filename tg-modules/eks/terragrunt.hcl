# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("../../environments/${ get_env("ENVIRONMENT_NAME", "development") }/config.yaml"))
  default_outputs = {}
}

include "tf_main_config" {
  path = find_in_parent_folders()
}

dependencies {
  paths = [
    "../../tg-modules//vpc"
  ]
}

dependency "vpc" {
  config_path = "../../tg-modules//vpc"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    vpcs = {
      "vpc_eu-west-1_${local.config.network.default_vpc}":      { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_eu-west-1_${local.config.network.default_vpc}_default": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_ap-south-1_${local.config.network.default_vpc}":     { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_ap-south-1_${local.config.network.default_vpc}_default": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_ap-southeast-1_${local.config.network.default_vpc}": { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_ap-southeast-1_${local.config.network.default_vpc}_default": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_eu-central-1_${local.config.network.default_vpc}":   { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_eu-central-1_${local.config.network.default_vpc}_default": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_us-east-1_${local.config.network.default_vpc}":      { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_us-east-1_${local.config.network.default_vpc}_default": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_us-east-2_${local.config.network.default_vpc}":      { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_us-east-2_${local.config.network.default_vpc}_default": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
    }
  }
}

generate "versions" {
  path      = "versions_override.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
    terraform {
      required_providers {
        kubernetes = {
          source = "hashicorp/kubernetes"
          version = "2.20.0"
        }
      }
    }
EOF
}

inputs = {

  vpcs_json = dependency.vpc.outputs.vpcs

}

generate "dynamic-eks-modules" {
  path      = "dynamic-eks-modules.tf"
  if_exists = "overwrite"
  contents  = <<EOF

locals {
  environment = "${ chomp(try(local.config.general.environment, "development", local.ENVIRONMENT_NAME)) }"
  env_short   = "${ chomp(try(local.config.general.env-short, "dev")) }"
  project     = "${ chomp(try(local.config.general.project, "PROJECT_NAME")) }"
}

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

    %{ for rolename in try(eks_values.aws-auth-extra-roles, [] ) ~}

data "aws_iam_roles" "aws_auth_extra_role_${eks_region_k}_${eks_name}_${ replace("${rolename}", "*", "wildcard")}" {
  name_regex = "${rolename}"
}

    %{ endfor ~}

module "label_${eks_region_k}_${eks_name}" {

  source = "cloudposse/label/null"
  version  = "0.25.0"

  stage      = ""
  namespace  = ""
  name       = "$${local.env_short}-${eks_name}-${eks_region_k}"
  delimiter  = "-"
  attributes = ["cluster"]
}

module "eks_cluster_${eks_region_k}_${eks_name}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source = "${ chomp(try(local.config.eks.cluster-module-source, "cloudposse/eks-cluster/aws")) }"
  %{ if try(regex("git::", local.config.eks.cluster-module-source), "") != "git::" }
  version = "${ chomp(try(local.config.eks.cluster-module-version, "4.4.1")) }"
  %{ endif ~}
  context = module.label_${eks_region_k}_${eks_name}.context

  region     = "${eks_region_k}"

  subnet_ids = concat(
  %{ for subnet in try(eks_values.network.subnets, []) ~}
    jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.subnets_info.subnet_${eks_region_k}_${eks_values.network.vpc}_${subnet.name}.${subnet.kind}_subnet_ids,
  %{ endfor ~}
  )

  kubernetes_version    = "${ chomp(try("${eks_values.k8s-version}", "1.31") ) }"
  oidc_provider_enabled = true
  endpoint_private_access = "${ chomp(try("${eks_values.endpoint-private-access}", true) ) }"
  endpoint_public_access = "${ chomp(try("${eks_values.endpoint-public-access}", false) ) }"
  cluster_log_retention_period = "${ chomp(try("${eks_values.cluster-log-retention-period}", 7) ) }"

  %{ if try(eks_values.public-access-cidrs, "") != "" }
  public_access_cidrs = concat(
    %{ for cird_name, cidr_value in eks_values.public-access-cidrs ~}
    ["${cidr_value}"],
    %{ endfor ~}
  )
  %{ endif ~}

  %{ if try(eks_values.network.allowed-cidr-blocks, "") != "" }
  allowed_cidr_blocks = concat(
    %{ for cird_name, cidr_value in eks_values.network.allowed-cidr-blocks ~}
    ["${cidr_value}"],
    %{ endfor ~}
  )
  %{ endif ~}

  addons = [ 
    %{ if try(eks_values.addons, "") != "" }
      %{ for addon_name, addon_v in eks_values.addons ~}
     {
        addon_name =  "${addon_name}",
        addon_version = "${addon_v.addon-version}",
        %{ if try(addon_v.resolve-conflicts, "") != "" } resolve_conflicts = "${addon_v.resolve-conflicts}", %{ else } resolve_conflicts = "PRESERVE", %{ endif ~}
        %{ if try(addon_v.service-account-role-arn, "") != "" } service_account_role_arn = "${addon_v.service-account-role-arn}", %{ else } service_account_role_arn = null %{ endif ~}
        %{ if try(addon_v.env, "") != "" }
        configuration_values = jsonencode({
          env = {
            %{ for env_k, env_v in addon_v.env ~}
            ${env_k} = "${env_v}"
            %{ endfor ~}
          }
        })
        %{ endif ~}
     },
      %{ endfor ~}
    %{ endif ~}

  ]

  access_entry_map = {
  %{ for rolename in try(eks_values.aws-auth-extra-roles, [] ) ~}
    element(tolist(data.aws_iam_roles.aws_auth_extra_role_${eks_region_k}_${eks_name}_${ replace("${rolename}", "*", "wildcard")}.arns), 0) = {
      access_policy_associations = {
        ClusterAdmin = {}
      }
    },
  %{ endfor ~}
  }

}

resource "aws_iam_role_policy_attachment" "alb_policy_${eks_region_k}_${eks_name}" {
  policy_arn = aws_iam_policy.aws_alb_policy.arn
  role       = split("/", module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_role_arn)[1]
}

    %{ for eng_name, eng_values in eks_values.node-groups ~} 

module "node_group_label_${eks_region_k}_${eks_name}_${eng_name}" {

  source = "cloudposse/label/null"
  version  = "0.25.0"

  stage      = ""
  namespace  = ""
  name       = "$${local.env_short}-${eks_name}-${eng_name}-${eks_region_k}"
  delimiter  = "-"
  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}"
  }
}

      %{ if try(eng_values.exposed-ports, "") != "" } 

module "eks_node_group_sg_${eks_region_k}_${eks_name}_${eng_name}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source = "cloudposse/security-group/aws"
  version = "2.0.1"
  context = module.node_group_label_${eks_region_k}_${eks_name}_${eng_name}.context
  name = "$${local.env_short}-${eks_name}-${eng_name}-${eks_region_k}"

  vpc_id     = jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.vpc_info.vpc_id

  # Here we add an attribute to give the security group a unique name.
  attributes = ["eks-node-group-${eks_name}-${eng_name}"]

  # Allow unlimited egress
  allow_all_egress = true

  rules = [
    %{ for sg_rule, sg_rule_values in eng_values.exposed-ports ~}
    {
      type      = "ingress"
      from_port = ${sg_rule_values.number}
      to_port   = ${sg_rule_values.number}
      protocol  = "${sg_rule_values.protocol}"
      cidr_blocks = [ %{ for cidr_filter in sg_rule_values.cidr-filters ~} "${cidr_filter}", %{ endfor ~} ]
    },
    %{ endfor ~}
  ] 

}

     %{ endif ~}

module "eks_node_group_${eks_region_k}_${eks_name}_${eng_name}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source = "${ chomp(try(local.config.eks.node-group-module-source, "cloudposse/eks-node-group/aws")) }"
  %{ if try(regex("git::", local.config.eks.node-group-module-source), "") != "git::" }
  version = "${ chomp(try(local.config.eks.node-group-module-version, "3.1.1")) }"
  %{ endif ~}
  context = module.node_group_label_${eks_region_k}_${eks_name}_${eng_name}.context
  name = "$${local.env_short}-${eks_name}-${eng_name}-${eks_region_k}"

  instance_types = [%{ for type in eng_values.instance-types ~} "${type}", %{ endfor ~}]
  ami_type       = "${ chomp(try("${eng_values.ami-type}", "AL2_x86_64")) }"
  node_repair_enabled = ${ chomp(try("${eng_values.node-repair-enabled}", false) ) }

  %{ if eng_values.network.subnet.kind == "public" }
    %{ if try(eng_values.network.availability-zones, "") != "" }
  subnet_ids = [
      %{ for az in eng_values.network.availability-zones ~}
    element(jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.subnets_info.subnet_${eks_region_k}_${eks_values.network.vpc}_${eng_values.network.subnet.name}.az_public_subnets_map["${eks_region_k}${az}"], 0),
      %{ endfor ~}
  ]
    %{ else ~}
  subnet_ids                         = jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.subnets_info.subnet_${eks_region_k}_${eks_values.network.vpc}_${eng_values.network.subnet.name}.public_subnet_ids
    %{ endif ~}
  %{ else ~}
    %{ if try(eng_values.network.availability-zones, "") != "" }
  subnet_ids = [
      %{ for az in eng_values.network.availability-zones ~}
    element(jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.subnets_info.subnet_${eks_region_k}_${eks_values.network.vpc}_${eng_values.network.subnet.name}.az_private_subnets_map["${eks_region_k}${az}"], 0),
      %{ endfor ~}
  ]
    %{ else ~}
  subnet_ids                         = jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.subnets_info.subnet_${eks_region_k}_${eks_values.network.vpc}_${eng_values.network.subnet.name}.private_subnet_ids
    %{ endif ~}
  %{ endif ~}

  desired_size                       = ${ chomp(try("${eng_values.desired-size}", 1) ) }
  min_size                           = ${ chomp(try("${eng_values.min-size}", 1) ) }
  max_size                           = ${ chomp(try("${eng_values.max-size}", 1) ) }
  cluster_name                       = module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_id

  associated_security_group_ids      = [ %{ if try(eng_values.exposed-ports, "") != "" } module.eks_node_group_sg_${eks_region_k}_${eks_name}_${eng_name}.id %{ endif ~} ]

  # Enable the Kubernetes cluster auto-scaler to find the auto-scaling group
  cluster_autoscaler_enabled = ${ chomp(try("${eng_values.autoscaler-enabled}", false) ) } 

  create_before_destroy = true

  %{ if try(eng_values.block-device-mappings, "") != "" }
  block_device_mappings = [
  %{ for dm_name, dm_value in eng_values.block-device-mappings ~}
    {
      "device_name": "/dev/${dm_name}",
      "encrypted": ${dm_value.encrypted},
      "volume_size": ${dm_value.volume-size},
      "volume_type": "${dm_value.volume-type}"
    },
  %{ endfor ~}
  ]
  %{ endif ~}

  %{ if try(eng_values.node-taints, "") != "" }
  kubernetes_taints = [
  %{ for nt_name, nt_value in eng_values.node-taints ~}
    {
      key    = "${nt_name}"
      value  = "${nt_value.value}"
      effect = "${nt_value.effect}"
    },
  %{ endfor ~}
  ]
  %{ endif ~}

  kubernetes_labels = {
    %{ if try(eng_values.node-kubernetes-io-role, "") != "" }
    "node.kubernetes.io/role" = "${eng_values.node-kubernetes-io-role}"
    %{ else }
    "node.kubernetes.io/role" = "${eng_name}"
    %{ endif ~}
  }

  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}"
  }

}
      %{ if try(eng_values.max-pods, "") != "" }
# NOTE: this requires arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore to be attached to the node group role
# Create an aws_ssm_association that executes a script that will set --max-pods for kubelet
resource "aws_ssm_association" "set_max_pods_${eks_region_k}_${eks_name}_${eng_name}" {
  name = "AWS-RunShellScript"

  targets {
    key    = "tag:eks:nodegroup-name"
    values = [split(":", module.eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eks_node_group_id)[1]]
  }

  parameters = {
    commands = <<-EOC
      #!/bin/bash
      MAX_PODS=${eng_values.max-pods}
      KUBELET_ENV_FILE=/etc/eks/kubelet/environment
      grep -q "^NODEADM_KUBELET_ARGS=.*max-pods=$MAX_PODS" $KUBELET_ENV_FILE && exit 0
      sed -i "s|^NODEADM_KUBELET_ARGS=|NODEADM_KUBELET_ARGS=--max-pods=$MAX_PODS |" $KUBELET_ENV_FILE
      systemctl daemon-reload
      systemctl restart kubelet
EOC
  }
  # optional: only run once
  max_concurrency = "100%"
  max_errors      = "0"
}
      %{ endif ~}

      %{ if try(eng_values.swap, "") != "" }
        %{ if try(eng_values.swap.enabled, "") == false }
resource "aws_ssm_association" "disable_swap_${eks_region_k}_${eks_name}_${eng_name}" {
  name = "AWS-RunShellScript"
  targets {
    key    = "tag:eks:nodegroup-name"
    values = [split(":", module.eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eks_node_group_id)[1]]
  }
  parameters = {
    commands = <<-EOC
      #!/bin/bash
      SWAP_FILE=/swapfile
      KUBELET_CONFIG_FILE="/etc/kubernetes/kubelet/config.json.d/99-swap.conf"
      swapoff $SWAP_FILE
      sed -i '^/$SWAP_FILE.*/d' /etc/fstab
      rm -f $SWAP_FILE $KUBELET_CONFIG_FILE

      systemctl daemon-reload
      systemctl restart kubelet
EOC
  }
  # optional: only run once
  max_concurrency = "100%"
  max_errors      = "0"
}
        %{ endif ~}
        %{ if try(eng_values.swap.enabled, "") == true }
          %{ if try(eng_values.swap.size, "") != "" }
# NOTE: this requires arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore to be attached to the node group role
# Create an aws_ssm_association that executes a script that will enable swap on the nodes
resource "aws_ssm_association" "enable_swap_${eks_region_k}_${eks_name}_${eng_name}" {
  name = "AWS-RunShellScript"

  targets {
    key    = "tag:eks:nodegroup-name"
    values = [split(":", module.eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eks_node_group_id)[1]]
  }

  parameters = {
    commands = <<-EOC
      #!/bin/bash
      KUBELET_CONFIG_FILE="/etc/kubernetes/kubelet/config.json.d/99-swap.conf"
      SWAP_SIZE_GB=${eng_values.swap.size}
      SWAP_FILE=/swapfile
      fallocate -l $$${SWAP_SIZE_GB}G $SWAP_FILE
      chmod 600 $SWAP_FILE
      mkswap $SWAP_FILE
      swapon $SWAP_FILE
      grep -q $SWAP_FILE /etc/fstab || echo "$SWAP_FILE swap swap defaults 0 0" >> /etc/fstab

      echo 'vm.swappiness=10' > /etc/sysctl.d/99-kubernetes-swap.conf
      sysctl -p /etc/sysctl.d/99-kubernetes-swap.conf
 
      # Setting LimitedSwap allows pods to burst memory usage into swap. Default is NoSwap, which would only let host processes (kubelet, ssm) use swap.
      cat <<EOCAT > $KUBELET_CONFIG_FILE
      {
          "apiVersion": "kubelet.config.k8s.io/v1beta1",
          "kind": "KubeletConfiguration",
          "failSwapOn": false,
          "memorySwap": { "swapBehavior": "${ try(eng_values.swap.behavior, "LimitedSwap") }" }
      }
      EOCAT

      systemctl daemon-reload
      systemctl restart kubelet
EOC
  }
  # optional: only run once
  max_concurrency = "100%"
  max_errors      = "0"
}
        %{ endif ~}
      %{ endif ~}
    %{ endif ~}

resource "aws_iam_role_policy_attachment" "alb_ingress_policy_${eks_region_k}_${eks_name}_${eng_name}" {
  policy_arn = aws_iam_policy.aws_alb_policy.arn
  role       = module.eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eks_node_group_role_name
}

      %{ if try(eng_values.extra-iam-policies, "") != "" }
        %{ for iam_k, iam_v in eng_values.extra-iam-policies ~}

resource "aws_iam_role_policy_attachment" "ebs_policy_${eks_region_k}_${eks_name}_${eng_name}_${iam_k}" {
  policy_arn = "${iam_v}"
  role       = module.eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eks_node_group_role_name
}
        %{ endfor ~}
      %{ endif ~}

    %{ endfor ~}

    %{ for hng_name, hng_values in try(eks_values.hybrid-node-groups, {}) ~}

# ========================================
# Hybrid Node Group: ${hng_name}
# Region: ${ try(hng_values.network.region, eks_region_k) }
# ========================================

module "hybrid_node_group_label_${eks_region_k}_${eks_name}_${hng_name}" {

  source = "cloudposse/label/null"
  version  = "0.25.0"

  stage      = ""
  namespace  = ""
  name       = "$${local.env_short}-${eks_name}-hybrid-${hng_name}-${ try(hng_values.network.region, eks_region_k) }"
  delimiter  = "-"
  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}",
    "kubernetes.io/cluster/$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_id}" = "owned"
  }
}

# IAM Role for Hybrid Nodes (EC2 Instance Profile)
resource "aws_iam_role" "hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  name = "$${local.env_short}-${eks_name}-hybrid-${hng_name}-${ try(hng_values.network.region, eks_region_k) }"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = module.hybrid_node_group_label_${eks_region_k}_${eks_name}_${hng_name}.tags
}

# Attach required policies for EKS nodes
resource "aws_iam_role_policy_attachment" "hybrid_node_AmazonEKSWorkerNodePolicy_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name
}

resource "aws_iam_role_policy_attachment" "hybrid_node_AmazonEKS_CNI_Policy_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name
}

resource "aws_iam_role_policy_attachment" "hybrid_node_AmazonEC2ContainerRegistryReadOnly_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name
}

resource "aws_iam_role_policy_attachment" "hybrid_node_AmazonSSMManagedInstanceCore_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name
}

resource "aws_iam_role_policy_attachment" "hybrid_node_alb_policy_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  policy_arn = aws_iam_policy.aws_alb_policy.arn
  role       = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name
}

      %{ if try(hng_values.extra-iam-policies, "") != "" }
        %{ for iam_k, iam_v in hng_values.extra-iam-policies ~}

resource "aws_iam_role_policy_attachment" "hybrid_node_extra_policy_${eks_region_k}_${eks_name}_${hng_name}_${iam_k}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  policy_arn = "${iam_v}"
  role       = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name
}
        %{ endfor ~}
      %{ endif ~}

# IAM Instance Profile
resource "aws_iam_instance_profile" "hybrid_node_profile_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  name = "$${local.env_short}-${eks_name}-hybrid-${hng_name}-${ try(hng_values.network.region, eks_region_k) }"
  role = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name

  tags = module.hybrid_node_group_label_${eks_region_k}_${eks_name}_${hng_name}.tags
}

# Security Group for Hybrid Nodes
resource "aws_security_group" "hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  name_prefix = "$${local.env_short}-${eks_name}-hybrid-${hng_name}-"
  description = "Security group for hybrid node group ${hng_name}"
  vpc_id      = jsondecode(var.vpcs_json).vpc_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}.vpc_info.vpc_id

  tags = merge(
    module.hybrid_node_group_label_${eks_region_k}_${eks_name}_${hng_name}.tags,
    {
      Name = "$${local.env_short}-${eks_name}-hybrid-${hng_name}-${ try(hng_values.network.region, eks_region_k) }"
    }
  )
}

# Allow all egress
resource "aws_security_group_rule" "hybrid_node_egress_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id
}

# Allow communication from control plane to nodes (kubelet)
resource "aws_security_group_rule" "hybrid_node_ingress_from_control_plane_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_managed_security_group_id
  security_group_id        = aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id
  description              = "Allow kubelet API from control plane"
}

# Allow communication from control plane to nodes (HTTPS)
resource "aws_security_group_rule" "hybrid_node_ingress_https_from_control_plane_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_managed_security_group_id
  security_group_id        = aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id
  description              = "Allow HTTPS from control plane"
}

# Allow nodes to communicate with each other
resource "aws_security_group_rule" "hybrid_node_ingress_self_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id
  description       = "Allow nodes to communicate with each other"
}

# Allow control plane to communicate with nodes
resource "aws_security_group_rule" "control_plane_to_hybrid_nodes_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id
  security_group_id        = module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_managed_security_group_id
  description              = "Allow control plane to communicate with hybrid nodes"
}

      %{ if try(hng_values.exposed-ports, "") != "" } 
        %{ for sg_rule, sg_rule_values in hng_values.exposed-ports ~}

resource "aws_security_group_rule" "hybrid_node_exposed_port_${eks_region_k}_${eks_name}_${hng_name}_${sg_rule}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  type              = "ingress"
  from_port         = ${sg_rule_values.number}
  to_port           = ${sg_rule_values.number}
  protocol          = "${sg_rule_values.protocol}"
  cidr_blocks       = [ %{ for cidr_filter in sg_rule_values.cidr-filters ~} "${cidr_filter}", %{ endfor ~} ]
  security_group_id = aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id
  description       = "Exposed port: ${sg_rule}"
}
        %{ endfor ~}
      %{ endif ~}

# Get latest AMI
data "aws_ssm_parameter" "hybrid_node_ami_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  name = "/aws/service/eks/optimized-ami/$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_version}/${ try(hng_values.ami-type, "amazon-linux-2/recommended") }/image_id"
}

# Autoscaling Group using CloudPosse module
module "hybrid_node_asg_${eks_region_k}_${eks_name}_${hng_name}" {
  source  = "cloudposse/ec2-autoscale-group/aws"
  version = "0.40.0"

  providers = {
    aws = aws.${ try(hng_values.network.region, eks_region_k) }
  }

  context = module.hybrid_node_group_label_${eks_region_k}_${eks_name}_${hng_name}.context
  name    = "$${local.env_short}-${eks_name}-hybrid-${hng_name}-${ try(hng_values.network.region, eks_region_k) }"

  image_id      = data.aws_ssm_parameter.hybrid_node_ami_${eks_region_k}_${eks_name}_${hng_name}.value
  instance_type = element([%{ for type in hng_values.instance-types ~} "${type}", %{ endfor ~}], 0)
  
      %{ if try(hng_values.spot-enabled, false) == true }
  instance_market_options = {
    market_type = "spot"
        %{ if try(hng_values.spot-max-price, "") != "" }
    spot_options = {
      max_price = "${ hng_values.spot-max-price }"
    }
        %{ endif ~}
  }
      %{ endif ~}

  iam_instance_profile_name = aws_iam_instance_profile.hybrid_node_profile_${eks_region_k}_${eks_name}_${hng_name}.name
  security_group_ids        = [aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id]

      %{ if hng_values.network.subnet.kind == "public" }
        %{ if try(hng_values.network.availability-zones, "") != "" }
  subnet_ids = [
          %{ for az in hng_values.network.availability-zones ~}
    element(jsondecode(var.vpcs_json).vpc_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}.subnets_info.subnet_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}_${hng_values.network.subnet.name}.az_public_subnets_map["${ try(hng_values.network.region, eks_region_k) }${az}"], 0),
          %{ endfor ~}
  ]
        %{ else ~}
  subnet_ids = jsondecode(var.vpcs_json).vpc_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}.subnets_info.subnet_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}_${hng_values.network.subnet.name}.public_subnet_ids
        %{ endif ~}
      %{ else ~}
        %{ if try(hng_values.network.availability-zones, "") != "" }
  subnet_ids = [
          %{ for az in hng_values.network.availability-zones ~}
    element(jsondecode(var.vpcs_json).vpc_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}.subnets_info.subnet_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}_${hng_values.network.subnet.name}.az_private_subnets_map["${ try(hng_values.network.region, eks_region_k) }${az}"], 0),
          %{ endfor ~}
  ]
        %{ else ~}
  subnet_ids = jsondecode(var.vpcs_json).vpc_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}.subnets_info.subnet_${ try(hng_values.network.region, eks_region_k) }_${hng_values.network.vpc}_${hng_values.network.subnet.name}.private_subnet_ids
        %{ endif ~}
      %{ endif ~}

  min_size         = ${ chomp(try("${hng_values.min-size}", 1) ) }
  max_size         = ${ chomp(try("${hng_values.max-size}", 3) ) }
  desired_capacity = ${ chomp(try("${hng_values.desired-size}", 1) ) }

  # Enable cluster autoscaler tags if requested
      %{ if try(hng_values.autoscaler-enabled, false) == true }
  tags = merge(
    module.hybrid_node_group_label_${eks_region_k}_${eks_name}_${hng_name}.tags,
    {
      "k8s.io/cluster-autoscaler/$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_id}" = "owned"
      "k8s.io/cluster-autoscaler/enabled" = "true"
    }
  )
      %{ else ~}
  tags = module.hybrid_node_group_label_${eks_region_k}_${eks_name}_${hng_name}.tags
      %{ endif ~}

      %{ if try(hng_values.block-device-mappings, "") != "" }
  block_device_mappings = [
        %{ for dm_name, dm_value in hng_values.block-device-mappings ~}
    {
      device_name = "/dev/${dm_name}"
      ebs = {
        volume_size           = ${dm_value.volume-size}
        volume_type           = "${dm_value.volume-type}"
        delete_on_termination = ${dm_value.delete-on-termination}
        encrypted             = ${dm_value.encrypted}
      }
    },
        %{ endfor ~}
  ]
      %{ endif ~}

  mixed_instances_policy = null
  health_check_type      = "EC2"
  wait_for_capacity_timeout = "10m"
}

# SSM Association for hybrid node bootstrap
resource "aws_ssm_association" "hybrid_node_bootstrap_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  name = "AWS-RunShellScript"

  targets {
    key    = "tag:Name"
    values = ["$${local.env_short}-${eks_name}-hybrid-${hng_name}-${ try(hng_values.network.region, eks_region_k) }"]
  }

  parameters = {
    commands = join("\n", [
      "#!/bin/bash",
      "set -ex",
      "",
      "# Configure AWS CLI region",
      "export AWS_DEFAULT_REGION=${ try(hng_values.network.region, eks_region_k) }",
      "",
      "# Get cluster information from SSM parameters",
      "CLUSTER_NAME=$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_id}",
      "CLUSTER_REGION=${eks_region_k}",
      "EKS_CLUSTER_VERSION=$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_version}",
      "API_SERVER_ENDPOINT=$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_endpoint}",
      "CERT_AUTHORITY=$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_certificate_authority_data}",
      "CLUSTER_CIDR=$${module.eks_cluster_${eks_region_k}_${eks_name}.eks_cluster_service_ipv4_cidr}",
      "",
      "# Check if node is already bootstrapped",
      "if systemctl is-active --quiet kubelet; then",
      "  echo 'Node already bootstrapped'",
      "  exit 0",
      "fi",
      "",
      "# Create NodeConfig for EKS Nodes",
      "cat > /tmp/nodeconfig.yaml <<NODECONFIG",
      "apiVersion: node.eks.aws/v1alpha1",
      "kind: NodeConfig",
      "spec:",
      "  cluster:",
      "    name: $${CLUSTER_NAME}",
      "    apiServerEndpoint: $${API_SERVER_ENDPOINT}",
      "    certificateAuthority: $${CERT_AUTHORITY}",
      "    cidr: $${CLUSTER_CIDR}",
%{ if try(hng_values.max-pods, "") != "" ~}
      "  kubelet:",
      "    config:",
      "      maxPods: ${hng_values.max-pods}",
%{ endif ~}
      "NODECONFIG",
      "",
      "# Install nodeadm if not already installed",
      "if ! command -v nodeadm &> /dev/null; then",
      "  echo 'Installing nodeadm...'",
      "  curl -o /tmp/nodeadm.tar.gz https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm.tar.gz",
      "  tar -xzf /tmp/nodeadm.tar.gz -C /usr/local/bin/",
      "  chmod +x /usr/local/bin/nodeadm",
      "fi",
      "",
      "# Install EKS dependencies using nodeadm",
      "echo 'Installing EKS dependencies...'",
      "nodeadm install $${EKS_CLUSTER_VERSION}",
      "",
      "# Initialize the node",
      "echo 'Initializing node...'",
      "nodeadm init -c file:///tmp/nodeconfig.yaml",
      "",
      "# Wait for kubelet to be ready",
      "echo 'Waiting for kubelet to become active...'",
      "for i in {1..30}; do",
      "  if systemctl is-active --quiet kubelet; then",
      "    echo 'Kubelet is active'",
      "    break",
      "  fi",
      "  echo \"Waiting for kubelet... ($i/30)\"",
      "  sleep 10",
      "done",
      "",
      "echo 'Hybrid node bootstrap completed successfully'"
    ])
  }
  
  max_concurrency = "100%"
  max_errors      = "0"
}

# SSM Association for cluster join and configuration
      %{ if try(hng_values.swap, "") != "" }
        %{ if try(hng_values.swap.enabled, "") == true }
          %{ if try(hng_values.swap.size, "") != "" }

resource "aws_ssm_association" "hybrid_node_enable_swap_${eks_region_k}_${eks_name}_${hng_name}" {
  provider = aws.${ try(hng_values.network.region, eks_region_k) }
  
  name = "AWS-RunShellScript"

  targets {
    key    = "tag:Name"
    values = ["$${local.env_short}-${eks_name}-hybrid-${hng_name}-${ try(hng_values.network.region, eks_region_k) }"]
  }

  parameters = {
    commands = <<-EOC
      #!/bin/bash
      KUBELET_CONFIG_FILE="/etc/kubernetes/kubelet/config.json.d/99-swap.conf"
      SWAP_SIZE_GB=${hng_values.swap.size}
      SWAP_FILE=/swapfile
      
      # Check if swap is already configured
      if swapon --show | grep -q $SWAP_FILE; then
        echo "Swap already configured"
        exit 0
      fi
      
      fallocate -l $${SWAP_SIZE_GB}G $SWAP_FILE
      chmod 600 $SWAP_FILE
      mkswap $SWAP_FILE
      swapon $SWAP_FILE
      grep -q $SWAP_FILE /etc/fstab || echo "$SWAP_FILE swap swap defaults 0 0" >> /etc/fstab

      echo 'vm.swappiness=10' > /etc/sysctl.d/99-kubernetes-swap.conf
      sysctl -p /etc/sysctl.d/99-kubernetes-swap.conf
 
      # Setting LimitedSwap allows pods to burst memory usage into swap
      cat <<EOCAT > $KUBELET_CONFIG_FILE
      {
          "apiVersion": "kubelet.config.k8s.io/v1beta1",
          "kind": "KubeletConfiguration",
          "failSwapOn": false,
          "memorySwap": { "swapBehavior": "${ try(hng_values.swap.behavior, "LimitedSwap") }" }
      }
      EOCAT

      systemctl daemon-reload
      systemctl restart kubelet
    EOC
  }
  
  max_concurrency = "100%"
  max_errors      = "0"
}
          %{ endif ~}
        %{ endif ~}
      %{ endif ~}

    %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}
EOF
}

generate "dynamic-outputs" {
  path      = "dynamic-eks-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output eks_clusters {

    value = merge(

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}
      {
        for key, value in module.eks_cluster_${eks_region_k}_${eks_name}[*]:
            "eks_cluster_${eks_region_k}_${eks_name}" => { "eks_info" = value }
      },

  %{ endfor ~}

%{ endfor ~}
   )
}

output eks_node_groups {

    value = merge(

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

    %{ for eng_name, eng_values in eks_values.node-groups ~} 
      {
        for key, value in module.eks_node_group_${eks_region_k}_${eks_name}_${eng_name}[*]:
            "eks_node_group_${eks_region_k}_${eks_name}_${eng_name}" => { "eng_info" = value }
      },
    %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}
   )
}

output eks_node_groups_sg {

    value = merge(

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

    %{ for eng_name, eng_values in eks_values.node-groups ~} 
      {
        %{ if try(eng_values.exposed-ports, "") != "" }
        for key, value in module.eks_node_group_sg_${eks_region_k}_${eks_name}_${eng_name}[*]:
            "eks_node_group_sg_${eks_region_k}_${eks_name}_${eng_name}" => { "eng_sg_info" = value }
        %{ endif ~}
      },
    %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}
   )
}

output hybrid_node_groups {

    value = merge(

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

    %{ for hng_name, hng_values in try(eks_values.hybrid-node-groups, {}) ~}
      {
        "hybrid_node_group_${eks_region_k}_${eks_name}_${hng_name}" = {
          asg_name = module.hybrid_node_asg_${eks_region_k}_${eks_name}_${hng_name}.autoscaling_group_name
          asg_id = module.hybrid_node_asg_${eks_region_k}_${eks_name}_${hng_name}.autoscaling_group_id
          iam_role_arn = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.arn
          iam_role_name = aws_iam_role.hybrid_node_role_${eks_region_k}_${eks_name}_${hng_name}.name
          security_group_id = aws_security_group.hybrid_node_sg_${eks_region_k}_${eks_name}_${hng_name}.id
        }
      },
    %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}
   )
}


EOF
}


terraform {

  extra_arguments "eks-workaround" {
    commands = [
      "init",
      "apply",
      "refresh",
      "import",
      "plan",
      "taint",
      "untaint",
      "destroy"
    ]
    env_vars = {
      KUBE_CONFIG_PATH = "~/.kube/aws-config"
    }
  }

  before_hook "kubeconfig_output_prepare" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["bash", "-c", "mkdir -p ~/.kube; touch ~/.kube/aws-config"]
  }

  before_hook "terraform_fmt" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["terraform", "fmt", "-recursive"]
  }

  source = ".//."

}
