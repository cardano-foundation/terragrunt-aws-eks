resource "aws_alb" "main" {
  name               = format("%s-%s", local.short_cluster_name, local.random_id)
  internal           = var.internal
  load_balancer_type = var.load_balancer_type
  security_groups    = [aws_security_group.main.id]
  subnets            = var.subnet_ids_list
  preserve_host_header = true
  drop_invalid_header_fields = true

  tags = merge({
    "ingress.k8s.aws/resource" = "LoadBalancer"
    "ingress.k8s.aws/cluster"  = var.cluster_name
  }, var.tags)
}

resource "aws_autoscaling_attachment" "asg_attachment_bar" {
  for_each = var.autoscale_group_names

  autoscaling_group_name = each.value
  lb_target_group_arn   = aws_alb_target_group.main.arn
}

resource "aws_alb_target_group" "main" {
  name_prefix = local.alb_name_prefix
  port        = var.node_port
  protocol    = var.node_port_protocol
  target_type = var.target_type
  vpc_id      = var.vpcid

  health_check {
    port                = var.node_port
    protocol            = "HTTP"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 6
    path                = "/"
    matcher             = "200-499"
  }

  stickiness {
    type          = var.stickiness_type
    enabled       = var.stickiness_enabled
    cookie_duration = var.stickiness_cookie_duration
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.cluster_name
  }

}

resource "aws_alb_listener" "http-forward" {
  count = var.enable_http && var.http_redirect == false ? 1 : 0

  load_balancer_arn = aws_alb.main.arn
  port              = var.http_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.main.arn
  }
}

resource "aws_alb_listener" "http-redirect" {
  count = var.enable_https && var.http_redirect ? 1 : 0

  load_balancer_arn = aws_alb.main.arn
  port              = var.http_port
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = var.https_port
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_alb_listener" "https" {
  count = var.enable_https ? 1 : 0

  load_balancer_arn = aws_alb.main.arn
  port              = var.https_port
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.main.arn
  }
}
