# Remote state: S3 with S3-native locking (use_lockfile, Terraform >= 1.10), so no DynamoDB
# table to run. Partial configuration: bucket/key/region come from envs/<env>.s3.tfbackend,
# one state object per environment.
#
#   terraform init -backend-config=envs/preprod.s3.tfbackend
#
# Stubbed: no bucket exists yet. CI and local checks write a backend_override.tf with a local
# backend instead (git-ignored). State holds no secret values by design (see README "Secrets").
terraform {
  backend "s3" {}
}
