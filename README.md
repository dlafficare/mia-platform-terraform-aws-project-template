# %project.name% Configurations

This repository contains the configuration of the %project.name% project. The project provisions **AWS** infrastructure with Terraform: the resources are composed in the Mia-Platform Console from the Software Catalog (Infrastructure Resources) and applied through HCP Terraform.

## How it works

1. Each Infrastructure Resource added in the Console writes a `<resource>.variables.tf` file under `manifests/terraform/environments/<ENV>/`, with the values of its form and the `_module_source` of the Terraform module.
2. Deploying from the Console triggers [`.github/workflows/pipeline.yml`](.github/workflows/pipeline.yml), which runs [`.github/scripts/generate-terraform.sh`](.github/scripts/generate-terraform.sh) to build the root `main.tf` (one module block and one output per resource).
3. The pipeline applies the configuration on the HCP Terraform workspace `mia-<project-name>-main-<env>`. AWS credentials are provided by HCP Terraform, not by this repository.
4. The generated files are committed under `environments/<ENV>/terraform/` for traceability.

Removing a resource and deploying destroys it on AWS.

## Linking resources

A form value written as `ref:<resource>.<output>` is replaced with the output of another resource of the project, e.g. `ref:auth.issuer_url`. References work also inside JSON fields:

```json
{"POST /sum": "ref:sum-fn.invoke_arn", "GET /stats": "ref:stats-fn.invoke_arn"}
```

Terraform creates the linked resources in the right order. Every resource output is visible in the **Outputs** tab of the HCP Terraform workspace.

## Prerequisites

- GitHub secret `TF_API_TOKEN` (HCP Terraform API token) available to this repository's environments
- HCP Terraform variable set with AWS credentials applied to the workspace
