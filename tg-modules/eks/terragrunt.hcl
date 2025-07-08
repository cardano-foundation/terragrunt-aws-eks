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
    "node.kubernetes.io/role" = "${eng_values.kubernetes-role}"
    %{ else }
    "node.kubernetes.io/role" = "${eng_name}"
    %{ endif ~}
  }

  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}"
  }

}

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
