locals {
  random_id  = substr(random_pet.this.id, 0, 8)
  alb_name_prefix = substr(random_uuid.this.id, 0, 6)
  short_cluster_name = substr(var.cluster_name, 0, 22)
}
