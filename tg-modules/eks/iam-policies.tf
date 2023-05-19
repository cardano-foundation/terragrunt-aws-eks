data "http" "aws_alb_policy_data" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.2.1/docs/install/iam_policy.json"
  request_headers = {
    Accept = "application/json"
  }
}

resource "aws_iam_policy" "aws_alb_policy" {
  name        = "${local.env_short}-${local.project}-eks-cluster-alb-ingress"
  policy = data.http.aws_alb_policy_data.response_body
}
