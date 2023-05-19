Input parameters
  
    * cluster_name: Cluster name to be Created (*required)
    * vpc_id: VPC ID to be linked with EKS cluster (*required)
    * subnet_ids_list: subnet ids as a list
    * autoscale_group_names: autoscaling group ids as a list
    * cluster_security_group_id: cluster security group id inorder to enable communication between loadbalancer to nodes
    * certificate_arn: certificate arn if https is enabled
    * internal       : true for internal alb else false
    * load_balancer_type : application/Network
    * target_type        : instance or ip 
    * access_logs          : To capture access logs; Please follow terraform syntax for the same https://www.terraform.io/docs/providers/aws/r/lb.html
    * tags                 : As a map if any tag
    * enable_deletion_protection : false 
    * cidr_blocks          : defaults to "0.0.0.0/0"   cidr blocks for inbound access
    * ssl_policy      : "ELBSecurityPolicy-2016-08"
    * certificate_arn : Cetificate arn
    * http_port       : defaults 80, http inbound port for alb
    * https_port      : defaults 443, https inbound port for alb
    * enable_http     : default false, attaches listener on port 80 (*required if not enable_https)
    * enable_https    : default false, attaches listener on port 443 (*required if not enable_http )
    * http_redirect   : default false, enables redirect from http to https
    * node_port       : null   # Please specify the nodeport of the application (*required)
    * cluster_security_group_id = cluster_security_group_id (*mandatory)
    
    Creates Route53 entries if route_53 is provided

    * domain_name: Domain name of the AWS account; It is used to retrieve the zone_id; ex: example.com
    * private_zone: true or false; defaults to false
    * host_name:  Complete host_name to be set; ex: abcd.example.com
    * region_prefix: us, eu

 Example:
 
    module "custom_alb" {
      source = "./modules/eks/alb"
    
      cluster_name    = local.cluster_name
      subnet_ids_list = ["subnet-************", "subnet-************"]
      vpcid           = var.vpcid
    
      autoscale_group_names     = [autoscale_group_names]
      cluster_security_group_id = cluster_security_group_id
    
        node_port   = 31121       #### Need to be hardcoded in NodePort service pods.
        enable_https = true       #### Just https routing enabled
        tags = {
          managedBy = "ALB Terraform"
        }
        certificate_arn = data.aws_acm_certificate.example.arn #### Required if https.
    
      route_53 = {
        domain_name = "anls.syncroncloud.team"
        host_name   = "dtna-test"
        region_prefix = "us"
      }
    }
