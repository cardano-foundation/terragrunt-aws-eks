output "dns_name" {
  value = aws_alb.main.dns_name
}

output "zone_id" {
  value = aws_alb.main.zone_id
}

output "alb_arn" {
  value = aws_alb.main.arn
}
