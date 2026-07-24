terraform {
  backend "s3" {
    bucket         = "alimf-aws-terraform-993015604240-us-east-1-an"
    key            = "dev/aws/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = true
    encrypt        = true
  }
}