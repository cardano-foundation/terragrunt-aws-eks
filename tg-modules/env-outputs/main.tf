output "eks_clusters" {
  value = jsondecode(var.eks_clusters_json)
}

output "eks_node_groups" {
  value = jsondecode(var.eks_node_groups_json)
}
