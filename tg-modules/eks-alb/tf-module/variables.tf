variable "cluster_name" {
  description = "Name of the eks cluster to which ALB need to be deployed."
  type        = string
}

variable "subnet_ids_list" {
  description = "List of subnet ids "
  type        = list(string)
}

variable "vpcid" {
  description = "VPC ID to be linked with EKS cluster"
  type        = string
}

variable "security_group_name" {
  default = "terraform-sg"
  type    = string
}

variable "internal" {
  default     = true
  description = "Load balancer scheme"
  type        = bool
}

variable "load_balancer_type" {
  default     = "application"
  description = "Type of loadbalancer - application or network"
  type        = string
}

variable "target_type" {
  default     = "instance"
  description = ""
  type        = string
}

variable "access_logs" {
  default     = {}
  description = "Access logs for ALB"
}

variable "tags" {
  default     = {}
  description = "Tags to add for ALB"
  type        = map
}

variable "enable_deletion_protection" {
  type    = bool
  default = false
}

variable "cidr_blocks" {
  type        = string
  default     = "0.0.0.0/0"
  description = "cidr blocks for inbound access"
}

variable "ssl_policy" {
  default = "ELBSecurityPolicy-2016-08"
  type    = string
}

variable "http_port" {
  default = 80
  type    = number
}

variable "https_port" {
  default = 443
  type    = number
}

variable "enable_http" {
  type    = bool
  default = false
}

variable "enable_https" {
  type    = bool
  default = true
}

variable "http_redirect" {
  type    = bool
  default = false
}

variable "node_port" {
  default     = "30443"
  description = "NodePort value"
}

variable "node_port_protocol" {
  default     = "HTTPS"
  description = "NodePort protocol value"
}

variable "certificate_arn" {
  default     = ""
  description = "Required if https is enabled"
}

variable "autoscale_group_names" {
  type        = any
  default     = {}
  description = "*Autoscaling group names of EKS cluster; ex: { node1: idddd }"
}

variable "cluster_security_group_ids" {
  type        = any
  description = "*EKS cluster security group IDs; Enables communication between Loadbalancer and EKS cluster"
  default     = {}
}

variable "stickiness_enabled" {
  type        = bool
  description = "Enable stickiness"
  default     = false
}

variable "stickiness_cookie_duration" {
  type        = number
  description = "Duration of stickiness cookie"
  default     = 86400
}

variable "stickiness_type" {
  type        = string
  description = "Type of stickiness"
  default     = "lb_cookie"
}
