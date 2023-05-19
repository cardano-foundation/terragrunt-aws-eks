# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("./environments/${ get_env("ENVIRONMENT_NAME", "development") }/config.yaml"))
  default_outputs = {}
}

generate "aws-provider" {
  path = "provider.tf"
  if_exists = "overwrite"
  contents = <<EOF
provider "aws" {
  profile = "${ chomp(get_env("AWS_PROFILE", "default")) }"
  region  = "${ chomp(try(local.config.general.region, "eu-west-1")) }"
  #alias   = "terragrunt"
  default_tags {
    tags = {
      Environment = "${ chomp(try(local.ENVIRONMENT_NAME)) }"
      Project = "${ chomp(try(local.config.general.project, "default")) }"
    }
  }
}

%{ for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, { } ) ~}

  %{ for vpc_name, vpc_values in vpc_region_v ~}

provider "aws" {
  profile = "${ chomp(get_env("AWS_PROFILE", "default")) }"
  region  = "${vpc_region_k}"
  alias = "${vpc_region_k}"

  default_tags {
    tags = {
      Environment = "${ chomp(try(local.ENVIRONMENT_NAME)) }"
      Project     = "${ chomp(try(local.config.general.project, "default")) }"
    }
  }
}

  %{ endfor ~}

%{ endfor ~}

EOF
}

generate "terraform-tf" {
  path = "terraform.tf"
  if_exists = "overwrite"
  contents = <<EOF
terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.66.1"
    }
    template = {
      source  = "cloudposse/template"
      version = "~> 2.2.0"
    }
  }
}
EOF
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket         = "${local.config.general.s3bucket-tfstate}"
    region         = local.config.general.region
    encrypt        = true
    key            = "${ get_env("ENVIRONMENT_NAME", "development") }/${basename(get_terragrunt_dir())}/terraform.tfstate"
    dynamodb_table = "${local.config.general.dynamodb-tfstate}"
    profile        = "${ get_env("AWS_PROFILE", "default") }"
  }
}

terraform {

  source = "../../tg-modules//empty-module"

}
