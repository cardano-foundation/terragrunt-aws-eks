# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("config.yaml"))
  default_outputs = {}
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../tg-modules//env-outputs"
}
