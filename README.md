# terraform-aws-three-tier-app

A Terraform module to deploy the infrastructure for a three-tier application on AWS.

<!-- BEGIN_TF_DOCS -->
## Usage

### main.tf
```hcl
# tflint-ignore: terraform_required_version
module "three_tier_app" {
  source  = "app.terraform.io/craigsloggett-lab/three-tier-app/aws"
  version = "0.0.1"
}
```

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.0 |

## Providers

No providers.

## Inputs

No inputs.

## Resources

No resources.

## Outputs

No outputs.
<!-- END_TF_DOCS -->
