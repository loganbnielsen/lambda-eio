# Provisions the ECR repository + IAM roles examples/echo-lambda/'s real
# deployment (see its README) needs: one repo for the image, one execution
# role the Lambda service itself assumes, and one deploy role a human/CI
# assumes to push images and create/invoke the function. Does not create the
# Lambda function itself — that's tied to "which image tag is deployed right
# now," a deploy-time action (see examples/echo-lambda/README.md), not
# static infra.
#
# No long-lived IAM access keys for the deploy role: assumable by whatever
# principal(s) you name in trusted_principal_arns, via `aws sts assume-role`.
#
# Usage:
#   terraform init
#   terraform apply \
#     -var 'trusted_principal_arns=["arn:aws:iam::ACCOUNT_ID:user/you"]'
#
#   aws sts assume-role \
#     --role-arn "$(terraform output -raw deploy_role_arn)" \
#     --role-session-name lambda-eio-echo-deploy
#   # export the returned credentials, then follow examples/echo-lambda/README.md,
#   # using `terraform output -raw ecr_repository_url` and
#   # `terraform output -raw execution_role_arn` in place of the placeholders there.
#
#   terraform destroy   # when done (add -var force_delete=true if the repo still has images)

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "function_name" {
  type    = string
  default = "lambda-eio-echo"
}

variable "trusted_principal_arns" {
  type        = list(string)
  description = "ARNs allowed to assume the deploy role (your IAM user/role, or a CI OIDC role)"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "echo" {
  name                 = var.function_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # a test/example repo — ok to destroy with images still in it
}

# ── Execution role: assumed by the Lambda service itself at invoke time ───── #

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.function_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "execution_basic" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── Deploy role: assumed by a human/CI to push images and manage the function ─ #

data "aws_iam_policy_document" "deploy_permissions" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level scoping
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.echo.arn]
  }
  statement {
    sid       = "LambdaManageThisFunctionOnly"
    actions   = ["lambda:CreateFunction", "lambda:UpdateFunctionCode", "lambda:InvokeFunction", "lambda:GetFunction", "lambda:DeleteFunction"]
    resources = ["arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}"]
  }
  statement {
    sid       = "PassExecutionRoleToLambda"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn]
  }
}

resource "aws_iam_policy" "deploy" {
  name   = "${var.function_name}-deploy"
  policy = data.aws_iam_policy_document.deploy_permissions.json
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.function_name}-deploy"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.echo.repository_url
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}
