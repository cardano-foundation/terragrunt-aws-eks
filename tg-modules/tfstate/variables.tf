variable "project" {
  description = "The project name."
}

variable "env-short" {
  description = "Environment short name to be used as prefix/sufix"
}

variable "s3bucket-tfstate" {}
variable "dynamodb-tfstate" {}
