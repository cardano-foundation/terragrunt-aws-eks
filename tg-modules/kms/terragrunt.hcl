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
    "../../tg-modules//eks"
  ]
}

dependency "eks" {
  config_path = "../../tg-modules//eks"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    eks_clusters = {}
    eks_node_groups = {}
    eks_node_groups_sg = {}
  }
}

inputs = {

  eks_clusters_json = dependency.eks.outputs.eks_clusters
  eks_node_groups_json = dependency.eks.outputs.eks_node_groups

}

generate "dynamic-kms-resources" {
  path      = "dynamic-kms-records.tf"
  if_exists = "overwrite"
  contents  = <<EOF

locals {
  env_short = "${ chomp(try(local.config.general.env-short, "dev")) }"
  project = "${ chomp(try(local.config.general.project, "PROJECT_NAME")) }"
}

data "aws_caller_identity" "current" {}

module "kms_multi_region" {

  source                  = "cloudposse/kms-key/aws"
  version                 = "0.12.1"
  description             = "$${local.env_short}-$${local.project} kms"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true 
  alias                   = "alias/$${local.env_short}-$${local.project}-multi-region"

}

resource "aws_iam_policy" "kms_multi_region" {

  name = "$${local.env_short}-$${local.project}-multi-region-kms"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action": [
            "kms:*"
        ],
        "Effect" : "Allow",
        "Resource" : [
          "arn:aws:kms:*:$${data.aws_caller_identity.current.account_id}:key/$${module.kms_multi_region.key_id}"
        ]
      },
    ]
  })
}

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

module "kms_${eks_region_k}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source                  = "cloudposse/kms-key/aws"
  version                 = "0.12.1"
  description             = "$${local.env_short}-$${local.project} kms"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false
  alias                   = "alias/$${local.env_short}-$${local.project}-${eks_region_k}"

}

resource "aws_iam_policy" "kms_${eks_region_k}" {

  name = "$${local.env_short}-$${local.project}-${eks_region_k}-kms"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action": [
            "kms:*"
        ],
        "Effect" : "Allow",
        "Resource" : [
          "arn:aws:kms:*:$${data.aws_caller_identity.current.account_id}:key/$${module.kms_${eks_region_k}.key_id}"
        ]
      },
    ]
  })
}

  %{ for eks_name, eks_values in eks_region_v ~}

    %{ for eng_name, eng_values in eks_values.node-groups ~}

resource "aws_iam_role_policy_attachment" "kms_policy_${eks_region_k}_${eks_name}_${eng_name}" {
  policy_arn = aws_iam_policy.kms_multi_region.arn
  role       = jsondecode(var.eks_node_groups_json).eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eng_info.eks_node_group_role_name
}

resource "aws_iam_role_policy_attachment" "kms_regional_policy_${eks_region_k}_${eks_name}_${eng_name}" {
  policy_arn = aws_iam_policy.kms_${eks_region_k}.arn
  role       = jsondecode(var.eks_node_groups_json).eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eng_info.eks_node_group_role_name
}

    %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}

EOF
}

generate "dynamic-outputs" {
  path      = "dynamic-kms-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output kms_multi_region_key_arn {
  value = module.kms_multi_region.key_arn
}

output kms_multi_region_key_id {
  value = module.kms_multi_region.key_id
}

output kms_multi_region_alias_arn {
  value = module.kms_multi_region.alias_arn
}

output kms_multi_region_alias_name {
  value = module.kms_multi_region.alias_name
}

output kms_regional {

    value = merge(

%{ for kms_regional_region_k, kms_regional_region_v in try(local.config.eks.regions, { } ) ~}

      {
        for key, value in module.kms_${kms_regional_region_k}[*]:
            "kms_regional_${kms_regional_region_k}" => { "kms_regional_info" = value }
      },

%{ endfor ~}
   )
}

EOF
}

terraform {

  source = ".//."

  before_hook "terraform_fmt" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["terraform", "fmt", "-recursive"]
  }

}
