# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("../../environments/${ get_env("ENVIRONMENT_NAME", "development") }/config.yaml"))
  default_outputs = {}
}

include "tf_main_config" {
  path = find_in_parent_folders()
}

generate "dynamic-network-modules" {
  path      = "dynamic-vpc-modules.tf"
  if_exists = "overwrite"
  contents  = <<EOF

%{ for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, { } ) ~}

  %{ for vpc_name, vpc_values in vpc_region_v ~}

module "vpc_${vpc_region_k}_${vpc_name}" {

  providers = {
    aws = aws.${vpc_region_k}
  }

  source = "${ chomp(try(local.config.network.vpc.vpc-module-source, "cloudposse/vpc/aws")) }"
  version = "${ chomp(try(local.config.network.vpc.vpc-module-version, "2.0.0")) }"
  namespace = ""
  stage     = ""
  name      = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}"

  ipv4_primary_cidr_block = "${vpc_values.ipv4-cidr}"

  assign_generated_ipv6_cidr_block = true
}

    %{ for sn_name, sn_values in vpc_values.subnets ~}

module "subnet_${vpc_region_k}_${vpc_name}_${sn_name}" {

  providers = {
    aws = aws.${vpc_region_k}
  }

  source = "${ chomp(try(local.config.network.vpc.subnet-module-source, "cloudposse/dynamic-subnets/aws")) }"
  version = "${ chomp(try(local.config.network.vpc.subnet-module-version, "2.0.4")) }"
  vpc_id             = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id
  igw_id             = [module.vpc_${vpc_region_k}_${vpc_name}.igw_id]
  namespace           = ""
  stage               = ""
  name                = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-${sn_name}"
  ipv4_cidr_block     = [ "${sn_values.ipv4-cidr}" ]
  private_subnets_enabled = ${sn_values.private_subnets_enabled}
  public_subnets_enabled = ${sn_values.public_subnets_enabled}
  public_route_table_enabled = ${sn_values.igw}
  nat_gateway_enabled = ${sn_values.ngw}
  availability_zones  = [ %{ for az_name in sn_values.availability-zones ~} "${az_name}", %{ endfor ~} ]

  public_subnets_additional_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnets_additional_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

}

    %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}
EOF
}


generate "dynamic-outputs" {
  path      = "dynamic-vpc-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output vpcs {

    value = merge(

%{ for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, { } ) ~}

  %{ for vpc_name, vpc_values in vpc_region_v ~}
      {
        for key, value in module.vpc_${vpc_region_k}_${vpc_name}[*]:
            "vpc_${vpc_region_k}_${vpc_name}" => { "vpc_info" = value, "subnets_info" = merge(
              %{ for sn_name, sn_values in vpc_values.subnets ~}
          
                { for key, value in module.subnet_${vpc_region_k}_${vpc_name}_${sn_name}[*]: "subnet_${vpc_region_k}_${vpc_name}_${sn_name}" => value },
        
              %{ endfor ~}
              
            )}
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
