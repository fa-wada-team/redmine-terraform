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

output "endpoint_create_command" {
  description = "インターフェイスエンドポイントを手動作成するコマンド (バージョンアップ作業前に実行。ttl_minutes 経過後に自動削除)"
  value       = "aws lambda invoke --region ${var.region} --function-name ${aws_lambda_function.endpoint_manager.function_name} --cli-binary-format raw-in-base64-out --payload '{\"action\":\"create\",\"ttl_minutes\":120}' /dev/stdout"
}

output "endpoint_delete_command" {
  description = "インターフェイスエンドポイントを手動削除するコマンド"
  value       = "aws lambda invoke --region ${var.region} --function-name ${aws_lambda_function.endpoint_manager.function_name} --cli-binary-format raw-in-base64-out --payload '{\"action\":\"delete\"}' /dev/stdout"
}

output "endpoint_status_command" {
  description = "インターフェイスエンドポイントの状態を確認するコマンド"
  value       = "aws lambda invoke --region ${var.region} --function-name ${aws_lambda_function.endpoint_manager.function_name} --cli-binary-format raw-in-base64-out --payload '{\"action\":\"status\"}' /dev/stdout"
}
