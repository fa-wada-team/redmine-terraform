################################################################################
# 稼働スケジュール (任意)
# 平日日中のみ稼働させると EC2 料金を約 60% 削減できる
################################################################################

data "aws_iam_policy_document" "scheduler_assume" {
  count = var.enable_schedule ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = var.enable_schedule ? 1 : 0

  name               = "${var.project}-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json
}

data "aws_iam_policy_document" "scheduler" {
  count = var.enable_schedule ? 1 : 0

  statement {
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [aws_instance.redmine.arn, aws_instance.nat.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count = var.enable_schedule ? 1 : 0

  name   = "start-stop-ec2"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}

resource "aws_scheduler_schedule" "start" {
  count = var.enable_schedule ? 1 : 0

  name                         = "${var.project}-start"
  schedule_expression          = var.schedule_start_cron
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler[0].arn
    input = jsonencode({
      InstanceIds = [aws_instance.nat.id, aws_instance.redmine.id]
    })
  }
}

resource "aws_scheduler_schedule" "stop" {
  count = var.enable_schedule ? 1 : 0

  name                         = "${var.project}-stop"
  schedule_expression          = var.schedule_stop_cron
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler[0].arn
    input = jsonencode({
      InstanceIds = [aws_instance.redmine.id, aws_instance.nat.id]
    })
  }
}
