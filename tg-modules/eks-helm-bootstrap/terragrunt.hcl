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
    "../../tg-modules//eks"
  ]
}

dependency "eks" {
  config_path = "../../tg-modules//eks"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    eks_clusters = {}
    eks_node_groups = {}
  }
}

inputs = {

  eks_clusters_json = dependency.eks.outputs.eks_clusters

}

generate "dynamic-helm-modules" {
  path      = "dynamic-helm-modules.tf"
  if_exists = "overwrite"
  contents  = <<EOF

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

data "aws_eks_cluster_auth" "eks_auth_${eks_region_k}_${eks_name}" {
  name  = jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id
}

provider "helm" {
  alias = "${eks_region_k}_${eks_name}"

  repository_config_path = "$${path.module}/.helm/repositories.yaml"
  repository_cache       = "$${path.module}/.helm"

  kubernetes {
    host                   = jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.eks_auth_${eks_region_k}_${eks_name}.token
  }

}

provider "kubernetes" {
  alias = "${eks_region_k}_${eks_name}"
  host                   = jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks_auth_${eks_region_k}_${eks_name}.token
}

data "template_file" "${eks_region_k}_${eks_name}_gp3_encrypted_manifest" {
  template = <<EOT
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: gp3-encrypted
parameters:
  type: gp3
  encrypted: "true"
provisioner: kubernetes.io/aws-ebs
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOT
}

data "template_file" "${eks_region_k}_${eks_name}_gp3_manifest" {
  template = <<EOT
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
parameters:
  type: gp3
  encrypted: "true"
provisioner: kubernetes.io/aws-ebs
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOT
}

resource "kubernetes_manifest" "${eks_region_k}_${eks_name}_gp3" {
  provider = kubernetes.${eks_region_k}_${eks_name}
  manifest = yamldecode(data.template_file.${eks_region_k}_${eks_name}_gp3_manifest.rendered)
}

resource "kubernetes_manifest" "${eks_region_k}_${eks_name}_gp3_encrypted" {
  provider = kubernetes.${eks_region_k}_${eks_name}
  manifest = yamldecode(data.template_file.${eks_region_k}_${eks_name}_gp3_encrypted_manifest.rendered)
}

resource "kubernetes_annotations" "${eks_region_k}_${eks_name}_gp2_disable_default" {

  force = true

  provider = kubernetes.${eks_region_k}_${eks_name}
  api_version = "storage.k8s.io/v1"
  kind = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [kubernetes_manifest.${eks_region_k}_${eks_name}_gp3]

  lifecycle {
    ignore_changes = all
  }
}

    %{ for chart_k, chart_v in eks_values.helm-charts ~}

data "template_file" "${eks_region_k}_${eks_name}_${chart_k}" {
  template = <<EOT
      %{if try(chart_v.valuesYAMLTemplate, "") != "" ~}
        %{for v1_k, v1_v in chart_v.valuesYAMLTemplate ~}
${v1_k}: ${v1_v}
        %{ endfor ~}
      %{ endif ~}
EOT
  vars = {
    clusterName = jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id
  }
}

resource "helm_release" "${eks_region_k}_${eks_name}_${chart_k}" {
  provider   = helm.${eks_region_k}_${eks_name}
  %{ if try("${chart_v.repository}", "") != "" }
  repository = "${chart_v.repository}"
  %{ endif ~}
  namespace  = "${ chomp(try("${chart_v.namespace}", "default")) }"
  create_namespace = true
  chart      = "${chart_k}"
  name       = "${chart_k}"

  %{if try(chart_v.valuesSet, "") != "" ~}
    %{for set_k, set_v in chart_v.valuesSet ~}
  set {
    name  = "${set_k}"
    value = "${set_v}"
  }
    %{ endfor ~}
  %{ endif ~}

  values = [<<EOT
$${data.template_file.${eks_region_k}_${eks_name}_${chart_k}.rendered}
EOT
  ]

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
