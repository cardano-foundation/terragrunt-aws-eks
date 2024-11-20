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
    "../../tg-modules//eks-helm-bootstrap",
    "../../tg-modules//kms"
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

dependency "kms" {
  config_path = "../../tg-modules//kms"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    kms_multi_region_key_arn = "Known after apply (this is a mocked input from terragrunt)"
    kms_regional = {}
  }
}

inputs = {

  eks_clusters_json = dependency.eks.outputs.eks_clusters
  eks_node_groups_json = dependency.eks.outputs.eks_node_groups
  kms_regional_json = dependency.kms.outputs.kms_regional 
  kms_multi_region_key_arn = dependency.kms.outputs.kms_multi_region_key_arn

}

generate "dynamic-ssm-resources" {
  path      = "dynamic-ssm-records.tf"
  if_exists = "overwrite"
  contents  = <<EOF

locals {
  env_short = "${ chomp(try(local.config.general.env-short, "dev")) }"
  project = "${ chomp(try(local.config.general.project, "PROJECT_NAME")) }"
  app_namespace = "${ chomp(try(local.config.general.app-namespace, "${ chomp(try(local.config.general.project, "PROJECT_NAME")) }")) }"
  docker_registry_url = "${ chomp(get_env("DOCKER_REGISTRY_URL", "registry.hub.docker.com")) }"
  docker_registry_user = "${ chomp(get_env("DOCKER_REGISTRY_USER", "user")) }"
  docker_registry_pass = "${ chomp(get_env("DOCKER_REGISTRY_PASS", "pass")) }"
  docker_registry_email = "${ chomp(get_env("DOCKER_REGISTRY_EMAIL", "web3-team-integrations@cardanofoundation.org")) }"
}

data "aws_caller_identity" "current" {}

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

resource "aws_iam_policy" "ssm_${eks_region_k}" {

  provider = aws.${eks_region_k}

  name = "$${local.env_short}-$${local.project}-${eks_region_k}-eks-ssm"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Action": [
            "ssm:Describe*",
            "ssm:Get*",
            "ssm:List*"
        ],
        "Effect" : "Allow",
        "Resource" : [
          "arn:aws:ssm:${eks_region_k}:$${data.aws_caller_identity.current.account_id}:parameter/$${local.project}/$${local.env_short}/*",
          "arn:aws:ssm:${eks_region_k}:$${data.aws_caller_identity.current.account_id}:parameter/system_user/$${local.env_short}-$${local.project}*"
        ]
      },
    ]
  })
}

  %{ for eks_name, eks_values in eks_region_v ~}

resource "random_password" "${eks_region_k}_${eks_name}_poo_api_password" {
  length           = 20
  special          = true
  override_special = "_%!?:;#"
}

module "${eks_region_k}_${eks_name}_store_write" {
  source  = "cloudposse/ssm-parameter-store/aws"
  # Cloud Posse recommends pinning every module to a specific version
  # version = "x.x.x"

  providers = {
    aws = aws.${eks_region_k}
  }

  kms_arn = jsondecode(var.kms_regional_json).kms_regional_${eks_region_k}.kms_regional_info.key_arn

  parameter_write = [
    {
      name        = "/$${local.project}/$${local.env_short}/docker/${eks_name}/DOCKER_REGISTRY_URL"
      value       = local.docker_registry_url
      type        = "SecureString"
      overwrite   = "true"
      description = "docker registry url"
    },
    {
      name        = "/$${local.project}/$${local.env_short}/docker/${eks_name}/DOCKER_REGISTRY_USER"
      value       = local.docker_registry_user
      type        = "SecureString"
      overwrite   = "true"
      description = "docker registry user"
    },
    {
      name        = "/$${local.project}/$${local.env_short}/docker/${eks_name}/DOCKER_REGISTRY_PASS"
      value       = local.docker_registry_pass
      type        = "SecureString"
      overwrite   = "true"
      description = "docker registry password"
    }
  ]

  tags = {
    ManagedBy = "Terragrunt"
  }
}

data "aws_eks_cluster_auth" "eks_auth_${eks_region_k}_${eks_name}" {
  name  = jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id
}

provider "kubernetes" {
  alias = "${eks_region_k}_${eks_name}"
  host                   = jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks_auth_${eks_region_k}_${eks_name}.token
}

data "template_file" "${eks_region_k}_${eks_name}_secrets_store" {

  template = <<EOT
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: ${eks_region_k}-${eks_name}
  namespace: $${local.app_namespace}
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${eks_region_k}
EOT
}

data "template_file" "${eks_region_k}_${eks_name}_app_ns" {

  template = <<EOT
apiVersion: v1
kind: Namespace
metadata:
  name: $${local.app_namespace}
EOT
}

data "template_file" "${eks_region_k}_${eks_name}_external_secrets" {

  template = <<EOT
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: $${local.project}-secrets
  namespace: $${local.app_namespace}
spec:
  # SecretStoreRef defines which SecretStore to use when fetching the secret data
  secretStoreRef:
    name: ${eks_region_k}-${eks_name}
    kind: SecretStore  # or ClusterSecretStore
    # Specify a blueprint for the resulting Kind=Secret
  target:
    name: $${local.project}-secrets
    template:
      # Use inline templates to construct your desired config file that contains your secret
      data:
        PLACEHOLDER: "REPLACE_ME"
        #SES_ACCESS_KEY_ID: "{{ .SES_ACCESS_KEY_ID | toString | trim }}"
  #data:
  #- secretKey: SES_SMTP_PASSWORD
  #  remoteRef:
  #    key: /$${local.project}/$${local.env_short}/ses/${eks_name}/admin/SES_SMTP_PASSWORD
EOT
}


resource "kubernetes_manifest" "${eks_region_k}_${eks_name}_external_secrets" {
  provider = kubernetes.${eks_region_k}_${eks_name}

  manifest = yamldecode(data.template_file.${eks_region_k}_${eks_name}_external_secrets.rendered)

  depends_on = [
    kubernetes_manifest.${eks_region_k}_${eks_name}_app_ns,
  ]

  field_manager {
    force_conflicts = true
  }

}

resource "kubernetes_manifest" "${eks_region_k}_${eks_name}_app_ns" {
  provider = kubernetes.${eks_region_k}_${eks_name}

  manifest = yamldecode(data.template_file.${eks_region_k}_${eks_name}_app_ns.rendered)

}

resource "kubernetes_manifest" "${eks_region_k}_${eks_name}_secrets_store" {
  provider = kubernetes.${eks_region_k}_${eks_name}

  manifest = yamldecode(data.template_file.${eks_region_k}_${eks_name}_secrets_store.rendered)

  depends_on = [
    kubernetes_manifest.${eks_region_k}_${eks_name}_app_ns,
  ]

}

resource "kubernetes_secret" "${eks_region_k}_${eks_name}_docker_cfg" {

  provider = kubernetes.${eks_region_k}_${eks_name}

  metadata {
    name = "docker-cfg"
    namespace = "$${local.app_namespace}"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "$${local.docker_registry_url}" = {
          "username" = "$${local.docker_registry_user}"
          "password" = "$${local.docker_registry_pass}"
          "email"    = "$${local.docker_registry_email}"
          "auth"     = base64encode("$${local.docker_registry_user}:$${local.docker_registry_pass}")
        }
      }
    })
  }

  depends_on = [
    kubernetes_manifest.${eks_region_k}_${eks_name}_app_ns
  ]

}

    %{ for eng_name, eng_values in eks_values.node-groups ~}

resource "aws_iam_role_policy_attachment" "ssm_eks_${eks_region_k}_${eks_name}_${eng_name}" {
  policy_arn = aws_iam_policy.ssm_${eks_region_k}.arn
  role       = jsondecode(var.eks_node_groups_json).eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eng_info.eks_node_group_role_name
}

    %{ endfor ~}

  %{ endfor ~}

%{ endfor ~}

EOF
}

terraform {

  source = ".//."

  before_hook "terraform_fmt" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["terraform", "fmt", "-recursive"]
  }

}
