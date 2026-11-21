# Run once from your machine: two IAM roles that GitHub Actions in this repo assumes with OIDC.
#   plan role:  read-only, used on pull requests and main to plan the guardrails
#   apply role: can only manage the budget, the cost alerts topic and the anomaly monitor, and only from main
# No access keys are stored anywhere.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

# GitHub's OIDC subject for this repo, in its immutable form (owner and repo with their numeric IDs).
# Find yours with: gh api repos/OWNER/REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
variable "github_sub_prefix" {
  type    = string
  default = "repo:dkojo@167027053/aws-cost-optimisation@1466491317"
}

# Terraform state for the guardrails lives in this bucket, under one key prefix
variable "state_bucket" {
  type    = string
  default = "danielkojomegbenu-tfstate"
}

locals {
  state_prefix = "aws-cost-optimisation"
  account_id   = data.aws_caller_identity.me.account_id
  topic_arn    = "arn:aws:sns:us-east-1:${local.account_id}:cost-alerts"
}

data "aws_caller_identity" "me" {}

# The GitHub OIDC provider already exists in the account (created for project 1)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan  = ["${var.github_sub_prefix}:ref:refs/heads/main", "${var.github_sub_prefix}:pull_request"]
    apply = ["${var.github_sub_prefix}:ref:refs/heads/main"]
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "github-cost-guardrails-plan"
  assume_role_policy = data.aws_iam_policy_document.trust["plan"].json
}

resource "aws_iam_role" "apply" {
  name               = "github-cost-guardrails-apply"
  assume_role_policy = data.aws_iam_policy_document.trust["apply"].json
}

resource "aws_iam_role_policy" "plan" {
  name = "read-cost-guardrails"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["budgets:ViewBudget", "budgets:ListTagsForResource"], Resource = "*" },
      { Effect = "Allow", Action = ["sns:GetTopicAttributes", "sns:ListTagsForResource"], Resource = local.topic_arn },
      { Effect = "Allow", Action = ["ce:GetAnomalyMonitors", "ce:GetAnomalySubscriptions", "ce:ListTagsForResource"], Resource = "*" },
      { Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.state_bucket}" },
      { Effect = "Allow", Action = "s3:GetObject", Resource = "arn:aws:s3:::${var.state_bucket}/${local.state_prefix}/*" },
    ]
  })
}

resource "aws_iam_role_policy" "apply" {
  name = "manage-cost-guardrails"
  role = aws_iam_role.apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "budgets:*", Resource = "*" },
      { Effect = "Allow", Action = "sns:*", Resource = local.topic_arn },
      {
        Effect = "Allow"
        Action = [
          "ce:CreateAnomalyMonitor", "ce:GetAnomalyMonitors", "ce:UpdateAnomalyMonitor", "ce:DeleteAnomalyMonitor",
          "ce:CreateAnomalySubscription", "ce:GetAnomalySubscriptions", "ce:UpdateAnomalySubscription", "ce:DeleteAnomalySubscription",
          "ce:TagResource", "ce:UntagResource", "ce:ListTagsForResource",
        ]
        Resource = "*"
      },
      { Effect = "Allow", Action = "s3:ListBucket", Resource = "arn:aws:s3:::${var.state_bucket}" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::${var.state_bucket}/${local.state_prefix}/*" },
    ]
  })
}

output "plan_role_arn" { value = aws_iam_role.plan.arn }
output "apply_role_arn" { value = aws_iam_role.apply.arn }
