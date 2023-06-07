dependencies {
  paths = [
    "../../tg-modules//tfstate",
    "../../tg-modules//eks",
    "../../tg-modules//eks-helm-bootstrap",
    "../../tg-modules//eks-alb",
    "../../tg-modules//route53"
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

inputs = {

  eks_clusters_json = dependency.eks.outputs.eks_clusters
  eks_node_groups_json = dependency.eks.outputs.eks_node_groups
  eks_node_groups_sg_json = dependency.eks.outputs.eks_node_groups_sg

}
