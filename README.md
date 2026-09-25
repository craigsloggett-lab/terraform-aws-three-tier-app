# terraform-module-template
A GitHub repository template for creating new Terraform module.

<!-- BEGIN_TF_DOCS -->
## Usage

### main.tf
```hcl
# tflint-ignore: terraform_required_version
module "my_module" {
  source = "<namespace>/<module>/<provider>"
  # version = "x.x.x"
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
