# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("../../environments/${ get_env("ENVIRONMENT_NAME", "development") }/config.yaml"))
  default_outputs = {}
}

include "tf_main_config" {
  path = find_in_parent_folders()
}

inputs = {
  project               = local.config.general.project
  env-short             = local.config.general.env-short
  s3bucket-tfstate      = "${local.config.general.env-short}-${local.config.general.project}-tfstate"
  dynamodb-tfstate      = "${local.config.general.env-short}-${local.config.general.project}-tfstate"
}

terraform {

  source = ".//."

  before_hook "terraform_fmt" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["terraform", "fmt", "-recursive"]
  }

}
