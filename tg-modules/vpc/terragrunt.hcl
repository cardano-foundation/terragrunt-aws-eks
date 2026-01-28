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
  version = "${ chomp(try(local.config.network.vpc.subnet-module-version, "2.4.2")) }"
  vpc_id             = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id
  igw_id             = [module.vpc_${vpc_region_k}_${vpc_name}.igw_id]
  namespace           = ""
  stage               = ""
  name                = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-${sn_name}"
  ipv4_cidr_block     = [ "${sn_values.ipv4-cidr}" ]
  private_subnets_enabled = ${sn_values.private_subnets_enabled}
  public_subnets_enabled = ${sn_values.public_subnets_enabled}
  public_route_table_enabled = ${sn_values.igw}
  private_route_table_enabled = ${sn_values.igw}
  ipv6_egress_only_igw_id = [module.vpc_${vpc_region_k}_${vpc_name}.igw_id]
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


generate "dynamic-vpc-peering" {
  path      = "dynamic-vpc-peering.tf"
  if_exists = "overwrite"
  contents  = <<EOF

%{ for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, { } ) ~}
  %{ for vpc_name, vpc_values in vpc_region_v ~}
    %{ if try(vpc_values.peering, "") != "" }
      %{ for peering_name, peering_values in vpc_values.peering ~}

# Add the aws_vpc_peering_connection_accepter resource in the peer VPC's region if the peer VPC is in a different region
        %{ if peering_values.peer-region != "" && peering_values.peer-region != vpc_region_k }
resource "aws_vpc_peering_connection_accepter" "peering_accepter_${peering_values.peer-region}_${peering_values.peer-vpc}_to_${vpc_name}" {
  provider = aws.${peering_values.peer-region}

  vpc_peering_connection_id = aws_vpc_peering_connection.peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}.id
  auto_accept              = true

  tags = {
    Name = "${local.config.general.env-short}-peering-${peering_values.peer-vpc}-to-${vpc_name}"
    Side = "Accepter"
  }
}
        %{ endif ~}

# VPC Peering from ${vpc_name} to ${peering_values.peer-vpc}
resource "aws_vpc_peering_connection" "peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}" {
  provider = aws.${vpc_region_k}
  
  vpc_id        = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id
  peer_vpc_id   = module.vpc_${peering_values.peer-region}_${peering_values.peer-vpc}.vpc_id
  peer_region   = ${peering_values.peer-region != "" ? "\"${peering_values.peer-region}\"" : "aws.${vpc_region_k}.region" }
  auto_accept   = false

  tags = {
    Name = "${local.config.general.env-short}-peering-${vpc_name}-to-${peering_values.peer-vpc}"
    Side = "Requester"
  }
}

# Add routes from ${vpc_name} subnets to ${peering_values.peer-vpc}
        %{ for sn_name, sn_values in vpc_values.subnets ~}
          %{ if sn_values.private_subnets_enabled }
resource "aws_route" "peering_route_${vpc_region_k}_${vpc_name}_${sn_name}_private_to_${peering_values.peer-vpc}" {
  provider = aws.${vpc_region_k}
  
  count = length(module.subnet_${vpc_region_k}_${vpc_name}_${sn_name}.private_route_table_ids)
  
  route_table_id            = module.subnet_${vpc_region_k}_${vpc_name}_${sn_name}.private_route_table_ids[count.index]
  destination_cidr_block    = module.vpc_${peering_values.peer-region}_${peering_values.peer-vpc}.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}.id
}
          %{ endif ~}
          %{ if sn_values.public_subnets_enabled }
resource "aws_route" "peering_route_${vpc_region_k}_${vpc_name}_${sn_name}_public_to_${peering_values.peer-vpc}" {
  provider = aws.${vpc_region_k}
  
  count = length(module.subnet_${vpc_region_k}_${vpc_name}_${sn_name}.public_route_table_ids)
  
  route_table_id            = module.subnet_${vpc_region_k}_${vpc_name}_${sn_name}.public_route_table_ids[count.index]
  destination_cidr_block    = module.vpc_${peering_values.peer-region}_${peering_values.peer-vpc}.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}.id
}
          %{ endif ~}
        %{ endfor ~}

# Add routes from ${peering_values.peer-vpc} subnets to ${vpc_name}
        %{ for peer_sn_name, peer_sn_values in try(local.config.network.vpc.regions[peering_values.peer-region][peering_values.peer-vpc].subnets, { } ) ~}
          %{ if peer_sn_values.private_subnets_enabled }
resource "aws_route" "peering_route_${peering_values.peer-region}_${peering_values.peer-vpc}_${peer_sn_name}_private_to_${vpc_name}" {
  provider = aws.${peering_values.peer-region}
  count = length(module.subnet_${peering_values.peer-region}_${peering_values.peer-vpc}_${peer_sn_name}.private_route_table_ids)
  route_table_id            = module.subnet_${peering_values.peer-region}_${peering_values.peer-vpc}_${peer_sn_name}.private_route_table_ids[count.index]
  destination_cidr_block    = module.vpc_${vpc_region_k}_${vpc_name}.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}.id
}
          %{ endif ~}
          %{ if peer_sn_values.public_subnets_enabled }
resource "aws_route" "peering_route_${peering_values.peer-region}_${peering_values.peer-vpc}_${peer_sn_name}_public_to_${vpc_name}" {
  provider = aws.${peering_values.peer-region}
  count = length(module.subnet_${peering_values.peer-region}_${peering_values.peer-vpc}_${peer_sn_name}.public_route_table_ids)
  route_table_id            = module.subnet_${peering_values.peer-region}_${peering_values.peer-vpc}_${peer_sn_name}.public_route_table_ids[count.index]
  destination_cidr_block    = module.vpc_${vpc_region_k}_${vpc_name}.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}.id
}
          %{ endif ~}
        %{ endfor ~}

      %{ endfor ~}
    %{ endif ~}
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

output vpc_peering_connections {
  value = merge(
%{ for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, { } ) ~}
  %{ for vpc_name, vpc_values in vpc_region_v ~}
    %{ if try(vpc_values.peering, "") != "" }
      %{ for peering_name, peering_values in vpc_values.peering ~}
    {
      "peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}" = {
        id = aws_vpc_peering_connection.peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}.id
        status = aws_vpc_peering_connection.peering_${vpc_region_k}_${vpc_name}_to_${peering_values.peer-vpc}.accept_status
      }
    },
      %{ endfor ~}
    %{ endif ~}
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
