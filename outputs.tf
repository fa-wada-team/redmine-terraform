output "redmine_url" {
  description = "Redmine の URL"
  value       = local.use_custom_domain ? "https://${var.custom_domain}" : "https://${aws_cloudfront_distribution.redmine.domain_name}"
}

output "cloudfront_domain_name" {
  description = "CloudFront のドメイン名"
  value       = aws_cloudfront_distribution.redmine.domain_name
}

output "redmine_instance_id" {
  description = "Redmine EC2 のインスタンス ID (SSM Session Manager 接続用)"
  value       = aws_instance.redmine.id
}

output "nat_instance_id" {
  description = "NAT インスタンスの ID"
  value       = aws_instance.nat.id
}

output "ssm_session_command" {
  description = "Redmine EC2 へのログインコマンド"
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.redmine.id}"
}
