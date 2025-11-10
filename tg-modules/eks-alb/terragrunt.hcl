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
    "../../tg-modules//eks",
    "../../tg-modules//vpc"
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

dependency "vpc" {
  config_path = "../../tg-modules//vpc"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    vpcs = {
      "vpc_eu-west-1_${local.config.network.default_vpc}":      { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_eu-west-1_${local.config.network.default_vpc}_pub": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_ap-south-1_${local.config.network.default_vpc}":     { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_ap-south-1_${local.config.network.default_vpc}_pub": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_ap-southeast-1_${local.config.network.default_vpc}": { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_ap-southeast-1_${local.config.network.default_vpc}_pub": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_eu-central-1_${local.config.network.default_vpc}":   { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_eu-central-1_${local.config.network.default_vpc}_pub": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_us-east-1_${local.config.network.default_vpc}":      { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_us-east-1_${local.config.network.default_vpc}_pub": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
      "vpc_us-east-2_${local.config.network.default_vpc}":      { "vpc_info": { "vpc_id": "a1b2c3" }, "subnets_info": { "subnet_us-east-2_${local.config.network.default_vpc}_pub": { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } } }
    }
  }
}

inputs = {

  eks_clusters_json = dependency.eks.outputs.eks_clusters
  eks_node_groups_json = dependency.eks.outputs.eks_node_groups
  eks_node_groups_sg_json = dependency.eks.outputs.eks_node_groups_sg
  vpcs_json = dependency.vpc.outputs.vpcs

}

generate "dynamic-alb-modules" {
  path      = "dynamic-alb-modules.tf"
  if_exists = "overwrite"
  contents  = <<EOF

locals {

  main_app_hostname = "${ chomp(try(local.config.network.route53.main-app-hostname, "${local.config.general.env-short}.${local.config.general.project}")) }"

  uuid_domain_names = {

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}
    
    "${local.config.general.env-short}.${eks_name}.${eks_region_k}" = substr(uuidv5("dns","${local.config.general.env-short}.${eks_region_k}.${eks_name}"), 0, 31)

  %{ endfor ~}

%{ endfor ~}

  }

}

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

module "acm_request_certificate_${eks_region_k}_${eks_name}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source = "cloudposse/acm-request-certificate/aws"
  version = "0.16.3"
  zone_name                         = "${ chomp(try(local.config.network.route53.zones.default.tld, "cluster.local")) }"
  domain_name                       = substr(format("%s.%s", "$${local.uuid_domain_names["${local.config.general.env-short}.${eks_name}.${eks_region_k}"]}", "${local.config.network.route53.zones.default.tld}"), -64, -1)
  process_domain_validation_options = true
  ttl                               = "60"
  subject_alternative_names         = distinct([
    "$${local.main_app_hostname}.${local.config.network.route53.zones.default.tld}",
    "*.$${local.main_app_hostname}.${local.config.network.route53.zones.default.tld}",

    "${local.config.general.env-short}.${eks_name}.${local.config.network.route53.zones.default.tld}",
    "*.${local.config.general.env-short}.${eks_name}.${local.config.network.route53.zones.default.tld}",

    "${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}",
    "*.${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}",

    "${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}",
    "*.${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}"
%{ for alb_hostname in try(local.config.network.alb.acm.extra-fqdn, { } ) ~}
    , "${alb_hostname}"
%{ endfor ~}
  ])
}

module "alb_${eks_region_k}_${eks_name}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source = "./tf-module"

  cluster_name              = split(":", jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id)[0]

  subnet_ids_list = concat(
  %{ for subnet in eks_values.network.subnets ~}
    %{ if subnet.kind == "public" }
  jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.subnets_info.subnet_${eks_region_k}_${eks_values.network.vpc}_${subnet.name}.${subnet.kind}_subnet_ids,
    %{ endif ~}
  %{ endfor ~}
  )

  vpcid                     = jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.vpc_info.vpc_id
  autoscale_group_names     = toset( [
    %{ for eng_name, eng_values in eks_values.node-groups ~}  
      %{ if try(eng_values.exposed-ports, "") != "" }
    flatten(jsondecode(var.eks_node_groups_json).eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eng_info.eks_node_group_resources[*][*].autoscaling_groups[*].name)[0],
      %{ endif ~}
    %{ endfor ~}
  ] )
  cluster_security_group_ids = toset( [
    %{ for eng_name, eng_values in eks_values.node-groups ~}  
      %{ if try(eng_values.exposed-ports, "") != "" }
    jsondecode(var.eks_node_groups_sg_json).eks_node_group_sg_${eks_region_k}_${eks_name}_${eng_name}.eng_sg_info.id,
      %{ endif ~}
    %{ endfor ~}
  ] )
  tags                      = {}
  node_port                 = ${ chomp(try(eks_values.alb.node-port, 30443)) }
  node_port_protocol        = "${ chomp(try(eks_values.alb.node-port-protocol, "HTTPS")) }"
  node_port_protocol_version = "${ chomp(try(eks_values.alb.node-port-protocol-version, "HTTP1")) }"
  enable_http               = ${ chomp(try(eks_values.alb.enable-http, true)) }
  enable_https              = ${ chomp(try(eks_values.alb.enable-https, true)) }
  http_redirect             = ${ chomp(try(eks_values.alb.http-redirect, true)) }
  certificate_arn           = module.acm_request_certificate_${eks_region_k}_${eks_name}.arn
  internal                  = ${ chomp(try(eks_values.alb.internal, false)) }

}

  %{ endfor ~}

%{ endfor ~}
EOF
}

generate "dynamic-outputs" {
  path      = "dynamic-eks-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output eks_albs {

    value = merge(

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}
      {
        for key, value in module.alb_${eks_region_k}_${eks_name}[*]:
            "eks_alb_${eks_region_k}_${eks_name}" => { "alb_info" = value }
      },

  %{ endfor ~}

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
