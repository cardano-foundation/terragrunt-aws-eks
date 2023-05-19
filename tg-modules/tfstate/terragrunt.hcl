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
  s3bucket-tfstate      = local.config.general.s3bucket-tfstate
  dynamodb-tfstate      = local.config.general.dynamodb-tfstate
}

terraform {

  source = ".//."

}
