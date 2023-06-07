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
    "../../tg-modules//eks-alb"
  ]
}

dependency "eks-alb" {
  config_path = "../../tg-modules//eks-alb"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = { eks_albs = {} } 
}

inputs = {

  eks_alb_json = dependency.eks-alb.outputs.eks_albs

}

generate "dynamic-network-modules" {
  path      = "dynamic-route53-records.tf"
  if_exists = "overwrite"
  contents  = <<EOF

data "aws_route53_zone" "service_zone" {
  name = "${ chomp(try(local.config.network.route53.zones.default.tld, "cluster.local")) }"
}

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

resource "aws_route53_record" "eks_${eks_region_k}_${eks_name}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}"
  type    = "CNAME"
  ttl     = 60
  records = [try(jsondecode(var.eks_alb_json).eks_alb_${eks_region_k}_${eks_name}.alb_info.dns_name, "known-after-apply")]
}

      %{ for hostname in try(eks_values.alb-dns-aliases, [] ) ~}

resource "aws_route53_record" "eks_${eks_region_k}_${eks_name}_${ replace("${hostname}", ".", "_")}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${hostname}.${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_route53_record.eks_${eks_region_k}_${eks_name}.fqdn]
}

      %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}

EOF
}

terraform {

  source = ".//."

}
