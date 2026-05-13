# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("../../environments/${ get_env("ENVIRONMENT_NAME", "development") }/config.yaml"))
  default_outputs = {}
  unique_eks_names = distinct(flatten([
    for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) : [
      for eks_name, eks_values in eks_region_v : [
        eks_name
      ]
    ]
  ]))
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
  eks_hybrid_alb_json = dependency.eks-alb.outputs.eks_hybrid_albs
  unique_eks_names = local.unique_eks_names

}

generate "dynamic-network-modules" {
  path      = "dynamic-route53-records.tf"
  if_exists = "overwrite"
  contents  = <<EOF

data "aws_route53_zone" "service_zone" {
  name = "${ chomp(try(local.config.network.route53.zones.default.tld, "cluster.local")) }"
}

# per-region load balancer dns records

%{~ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{~ for eks_name, eks_values in try(eks_region_v, { } ) ~}

resource "aws_route53_record" "eks_${eks_region_k}_${eks_name}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}"
  type    = "CNAME"
  ttl     = 60
  records = [try(jsondecode(var.eks_alb_json).eks_alb_${eks_region_k}_${eks_name}.alb_info.dns_name, "known-after-apply")]
}

    %{~ for hng_name, hng_values in try(eks_values.hybrid-node-groups, {}) ~}
resource "aws_route53_record" "eks_${hng_values.network.region}_${eks_name}_${hng_name}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${local.config.general.env-short}.${eks_name}.${hng_values.network.region}.${local.config.network.route53.zones.default.tld}"
  type    = "CNAME"
  ttl     = 60
  records = [try(jsondecode(var.eks_hybrid_alb_json).eks_hybrid_alb_${hng_values.network.region}_${eks_name}_${hng_name}.alb_info.dns_name, "known-after-apply")]
}
    %{~ endfor ~}

      %{~ for hostname in try(eks_values.alb.dns-aliases, [] ) ~}

resource "aws_route53_record" "eks_${eks_region_k}_${eks_name}_${ replace("${hostname}", ".", "_")}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${hostname}.${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_route53_record.eks_${eks_region_k}_${eks_name}.fqdn]
}

        %{~ for hng_name, hng_values in try(eks_values.hybrid-node-groups, {}) ~}
 
resource "aws_route53_record" "eks_${hng_values.network.region}_${eks_name}_${hng_name}_${ replace("${hostname}", ".", "_")}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${hostname}.${local.config.general.env-short}.${eks_name}.${hng_values.network.region}.${local.config.network.route53.zones.default.tld}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_route53_record.eks_${hng_values.network.region}_${eks_name}_${hng_name}.fqdn]
}

        %{~ endfor ~}
        
      %{~ endfor ~}

  %{~ endfor ~}

%{~ endfor ~}

# multi-region load balancer dns records

%{~ for eks_name in local.unique_eks_names ~}

    %{~ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

resource "aws_route53_record" "rr_global_${eks_region_k}_${eks_name}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}"
  type    = "A"

  set_identifier = "eks_${eks_region_k}_${eks_name}"

  alias {
    name                   = try(jsondecode(var.eks_alb_json).eks_alb_${eks_region_k}_${eks_name}.alb_info.dns_name, "")
    zone_id                = try(jsondecode(var.eks_alb_json).eks_alb_${eks_region_k}_${eks_name}.alb_info.zone_id, "")
    evaluate_target_health = true
  }

  latency_routing_policy {
    region = "${eks_region_k}"
  }

}

      %{~ for eks_name, eks_values in try(eks_region_v, { } ) ~}

        %{~ for hng_name, hng_values in try(eks_values.hybrid-node-groups, {}) ~}
    
resource "aws_route53_record" "rr_global_${hng_values.network.region}_${eks_name}_${hng_name}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}"
  type    = "A"

  set_identifier = "eks_${eks_region_k}_${eks_name}-hng_${hng_values.network.region}_${hng_name}"

  alias {
    name                   = try(jsondecode(var.eks_hybrid_alb_json).eks_hybrid_alb_${hng_values.network.region}_${eks_name}_${hng_name}.alb_info.dns_name, "")
    zone_id                = try(jsondecode(var.eks_hybrid_alb_json).eks_hybrid_alb_${hng_values.network.region}_${eks_name}_${hng_name}.alb_info.zone_id, "")
    evaluate_target_health = true
  }

  latency_routing_policy {
    region = "${hng_values.network.region}"
  }
}
  
        %{~ endfor ~}
      %{~ endfor ~}
    %{~ endfor ~}

  %{~ for hostname in try(local.config.alb-dns-aliases, [] ) ~}

    %{~ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

resource "aws_route53_health_check" "rr_global_eks_${eks_region_k}_${eks_name}_${ replace("${hostname}", ".", "_")}_hc" {
  fqdn                            = try(jsondecode(var.eks_alb_json).eks_alb_${eks_region_k}_${eks_name}.alb_info.dns_name, "")
  port                            = 443
  type                            = "HTTPS"
  resource_path                   = "/ping"
  failure_threshold               = 3
  request_interval                = 10
  measure_latency                 = false
  invert_healthcheck              = false

}

resource "aws_route53_record" "rr_global_eks_${eks_region_k}_${eks_name}_${ replace("${hostname}", ".", "_")}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${hostname}.${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}"
  type    = "A"

  set_identifier = "eks_${eks_region_k}_${eks_name}_${ replace("${hostname}", ".", "_")}"

  health_check_id = aws_route53_health_check.rr_global_eks_${eks_region_k}_${eks_name}_${ replace("${hostname}", ".", "_")}_hc.id

  alias {
    name                   = try(jsondecode(var.eks_alb_json).eks_alb_${eks_region_k}_${eks_name}.alb_info.dns_name, "")
    zone_id                = try(jsondecode(var.eks_alb_json).eks_alb_${eks_region_k}_${eks_name}.alb_info.zone_id, "")
    evaluate_target_health = true
  }

  latency_routing_policy {
    region = "${eks_region_k}"
  }

}
      %{~ for eks_name, eks_values in try(eks_region_v, { } ) ~}
        %{~ for hng_name, hng_values in try(eks_values.hybrid-node-groups, {}) ~}

resource "aws_route53_health_check" "rr_global_eks_${hng_values.network.region}_${eks_name}_${hng_name}_${ replace("${hostname}", ".", "_")}_hc" {
  fqdn                            = try(jsondecode(var.eks_hybrid_alb_json).eks_hybrid_alb_${hng_values.network.region}_${eks_name}_${hng_name}.alb_info.dns_name, "")
  port                            = 443
  type                            = "HTTPS"
  resource_path                   = "/ping"
  failure_threshold               = 3
  request_interval                = 10
  measure_latency                 = false
  invert_healthcheck              = false

}

resource "aws_route53_record" "rr_global_eks_${hng_values.network.region}_${eks_name}_${hng_name}_${ replace("${hostname}", ".", "_")}" {
  zone_id = data.aws_route53_zone.service_zone.zone_id
  name    = "${hostname}.${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}"
  type    = "A"

  set_identifier = "eks_${eks_region_k}_${eks_name}_${ replace("${hostname}", ".", "_")}-hng_${hng_values.network.region}_${hng_name}"

  health_check_id = aws_route53_health_check.rr_global_eks_${hng_values.network.region}_${eks_name}_${hng_name}_${ replace("${hostname}", ".", "_")}_hc.id

  alias {
    name                   = try(jsondecode(var.eks_hybrid_alb_json).eks_hybrid_alb_${hng_values.network.region}_${eks_name}_${hng_name}.alb_info.dns_name, "")
    zone_id                = try(jsondecode(var.eks_hybrid_alb_json).eks_hybrid_alb_${hng_values.network.region}_${eks_name}_${hng_name}.alb_info.zone_id, "")
    evaluate_target_health = true
  }

  latency_routing_policy {
    region = "${hng_values.network.region}"
  }
}
        %{~ endfor ~}
      %{~ endfor ~}
    %{~ endfor ~}

  %{~ endfor ~}

%{~ endfor ~}

EOF
}

terraform {

  source = ".//."

  before_hook "terraform_fmt" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["terraform", "fmt", "-recursive"]
  }

}
