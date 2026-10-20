#!/bin/sh
# Generates the root Terraform configuration (main.tf) from the *.variables.tf files
# written by the Console infrastructure resources.
#
# Each variables file becomes a module block. A value written in the Console form as
#   ref:<resource>.<output>                     -> module.<resource>.<output>
#   {"key": "ref:<resource>.<output>", ...}     -> { "key": module.<resource>.<output>, ... }
# links resources together; Terraform then creates them in the right order.
#
# Required env: MODULES_BASE_DIR, TERRAFORM_WORK_DIR, WORKSPACE_NAME
# Optional env: TF_ORGANIZATION (default: mia-platform), TF_BACKEND (cloud|local, default: cloud)
set -eu

TF_ORGANIZATION="${TF_ORGANIZATION:-mia-platform}"
TF_BACKEND="${TF_BACKEND:-cloud}"
REF_PATTERN='"ref:([A-Za-z0-9_-]+)\.([A-Za-z0-9_]+)"'

VARS_FILES=$(find "${MODULES_BASE_DIR}" -type f -name "*.variables.tf" 2>/dev/null | sort || true)

if [ -z "$VARS_FILES" ]; then
  echo "No Terraform modules found in ${MODULES_BASE_DIR}"
  echo "Will proceed with empty configuration to allow resource cleanup"
else
  echo "Found $(echo "$VARS_FILES" | wc -l | tr -d ' ') module configuration(s):"
  for f in $VARS_FILES; do
    echo "  - $(basename "$f")"
  done
fi

mkdir -p "${TERRAFORM_WORK_DIR}"
MAIN_TF="${TERRAFORM_WORK_DIR}/main.tf"

echo "==> Generating main.tf header"
if [ "$TF_BACKEND" = "cloud" ]; then
  cat > "$MAIN_TF" << TFEOF
terraform {
  cloud {
    organization = "${TF_ORGANIZATION}"
    workspaces {
      name = "${WORKSPACE_NAME}"
    }
  }
TFEOF
else
  echo "terraform {" > "$MAIN_TF"
fi
cat >> "$MAIN_TF" << 'TFEOF'
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {}
TFEOF

for VARS_FILE in $VARS_FILES; do
  BASENAME=$(basename "$VARS_FILE")
  MODULE_NAME="${BASENAME%.variables.tf}"
  echo ""
  echo "Processing module: $MODULE_NAME"

  VAR_NAMES=$(grep -E '^\s*variable\s+"' "$VARS_FILE" | sed -E 's/.*variable[[:space:]]+"([^"]+)".*/\1/' | grep -v '^_module_source$' || true)

  # Copy the variables file, prefixing every variable with the module name
  sed -E \
    -e "s/variable \"([^\"]+)\"/variable \"${MODULE_NAME}_\1\"/" \
    -e "s/var\.([a-z_]+)/var.${MODULE_NAME}_\1/g" \
    "$VARS_FILE" > "${TERRAFORM_WORK_DIR}/${BASENAME}"

  # Evaluate all the values of the module at once
  CONSOLE_DIR=$(mktemp -d)
  cp "${TERRAFORM_WORK_DIR}/${BASENAME}" "${CONSOLE_DIR}/variables.tf"
  EXPR="jsonencode({ \"_module_source\" = var.${MODULE_NAME}__module_source"
  for VAR_NAME in $VAR_NAMES; do
    EXPR="${EXPR}, \"${VAR_NAME}\" = var.${MODULE_NAME}_${VAR_NAME}"
  done
  EXPR="${EXPR} })"
  if ! CONSOLE_OUT=$(cd "$CONSOLE_DIR" && echo "$EXPR" | terraform console -no-color 2>&1); then
    echo "ERROR: invalid configuration in $VARS_FILE:"
    echo "$CONSOLE_OUT"
    exit 1
  fi
  rm -rf "$CONSOLE_DIR"
  # terraform console prints the JSON document as a quoted string
  VALUES=$(printf '%s\n' "$CONSOLE_OUT" | jq -r '.')

  MODULE_SOURCE=$(printf '%s\n' "$VALUES" | jq -r '._module_source')
  if [ -z "$MODULE_SOURCE" ] || [ "$MODULE_SOURCE" = "null" ]; then
    echo "ERROR: _module_source is missing in $VARS_FILE"
    exit 1
  fi
  echo "  Module source: ${MODULE_SOURCE}"

  {
    echo ""
    echo "module \"${MODULE_NAME}\" {"
    echo "  source = \"${MODULE_SOURCE}\""
    echo ""
  } >> "$MAIN_TF"

  for VAR_NAME in $VAR_NAMES; do
    VALUE_JSON=$(printf '%s\n' "$VALUES" | jq -c --arg k "$VAR_NAME" '.[$k]')
    RAW=$(printf '%s\n' "$VALUE_JSON" | jq -r 'if type == "string" then . else tojson end')

    if printf '%s\n' "$RAW" | grep -Eq '^ref:[A-Za-z0-9_-]+\.[A-Za-z0-9_]+$'; then
      # Whole value is a reference to another resource
      HCL=$(printf '%s\n' "$RAW" | sed -E 's/^ref:([A-Za-z0-9_-]+)\.([A-Za-z0-9_]+)$/module.\1.\2/')
      echo "  Linking: ${VAR_NAME} = ${HCL}"
    elif JSON=$(printf '%s\n' "$RAW" | jq -ce 'select(type == "object" or type == "array")' 2>/dev/null); then
      # JSON object/array (form fields typed as JSON): passed as an HCL value so that its
      # keys are known at plan time, with references replaced by module outputs
      HCL=$(printf '%s\n' "$JSON" | sed -E "s/${REF_PATTERN}/module.\\1.\\2/g")
      if [ "$HCL" != "$JSON" ]; then echo "  Linking: ${VAR_NAME} = ${HCL}"; fi
    elif printf '%s\n' "$RAW" | grep -q 'ref:'; then
      echo "ERROR: ${MODULE_NAME}.${VAR_NAME} contains a reference but is neither 'ref:<resource>.<output>' nor a JSON object"
      exit 1
    else
      HCL="var.${MODULE_NAME}_${VAR_NAME}"
    fi
    echo "  ${VAR_NAME} = ${HCL}" >> "$MAIN_TF"
  done

  echo "}" >> "$MAIN_TF"

  # Expose the module outputs (URLs, IDs...) in the HCP Terraform workspace
  {
    echo ""
    echo "output \"${MODULE_NAME}\" {"
    echo "  value = module.${MODULE_NAME}"
    echo "}"
  } >> "$MAIN_TF"
done

echo ""
echo "==> Generated main.tf content:"
cat "$MAIN_TF"
