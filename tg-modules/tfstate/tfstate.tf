data "aws_s3_bucket" "terraform_deployment" {
  bucket = "${var.s3bucket-tfstate}"
}

resource "aws_s3_bucket_acl" "terraform_deployment_bucket_acl" {
  bucket = data.aws_s3_bucket.terraform_deployment.id
  acl    = "private"
  depends_on = [aws_s3_bucket_ownership_controls.s3_bucket_acl_ownership]
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "s3_bucket_acl_ownership" {
  bucket = data.aws_s3_bucket.terraform_deployment.id
  rule {
    object_ownership = "ObjectWriter"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_deployment_bucket_versioning" {
  bucket = data.aws_s3_bucket.terraform_deployment.id
  versioning_configuration {
    status = "Enabled"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_deployment_bucket_server_side_encryption_config" {
  bucket = data.aws_s3_bucket.terraform_deployment.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "AES256"
    }
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_deployment_bucket_blocking" {
  bucket = data.aws_s3_bucket.terraform_deployment.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  lifecycle {
    prevent_destroy = true
  }
}
