output "redmine_url" {
  description = "Redmine の URL"
  value       = local.use_custom_domain ? "https://${var.custom_domain}" : "https://${aws_cloudfront_distribution.redmine.domain_name}"
}

output "cloudfront_domain_name" {
  description = "CloudFront のドメイン名"
  value       = aws_cloudfront_distribution.redmine.domain_name
}

output "redmine_instance_id" {
  description = "Redmine EC2 のインスタンス ID"
  value       = aws_instance.redmine.id
}

output "ssh_command" {
  description = "Redmine EC2 へのログインコマンド (EC2 Instance Connect エンドポイント経由)"
  value       = "aws ec2-instance-connect ssh --region ${var.region} --instance-id ${aws_instance.redmine.id} --os-user ec2-user --connection-type eice"
}
