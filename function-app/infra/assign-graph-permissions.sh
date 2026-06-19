#!/usr/bin/env bash
# Assigns Microsoft Graph API permissions to the Function App's Managed Identity.
# Must be run AFTER Bicep deployment by a Privileged Role Administrator or Global Administrator.
#
# Usage:
#   chmod +x infra/assign-graph-permissions.sh
#   ./infra/assign-graph-permissions.sh <function-app-name> <resource-group>
#
# Example:
#   ./infra/assign-graph-permissions.sh func-defxdr-prod-a3f9 rg-defxdr-prod

set -euo pipefail

FUNCTION_APP_NAME="${1:?Usage: $0 <function-app-name> <resource-group>}"
RESOURCE_GROUP="${2:?Usage: $0 <function-app-name> <resource-group>}"

echo "==> Getting Managed Identity principal ID for: ${FUNCTION_APP_NAME}"
PRINCIPAL_ID=$(az functionapp identity show \
  --name "${FUNCTION_APP_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query principalId \
  --output tsv)
echo "    Principal ID: ${PRINCIPAL_ID}"

echo "==> Getting Microsoft Graph service principal ID"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
GRAPH_SP_ID=$(az ad sp list \
  --filter "appId eq '${GRAPH_APP_ID}'" \
  --query "[0].id" \
  --output tsv)
echo "    Graph SP ID: ${GRAPH_SP_ID}"

assign_role() {
  local role_name="$1"
  echo "==> Assigning ${role_name}..."
  ROLE_ID=$(az ad sp show \
    --id "${GRAPH_APP_ID}" \
    --query "appRoles[?value=='${role_name}'].id" \
    --output tsv)
  echo "    Role ID: ${ROLE_ID}"

  az rest \
    --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GRAPH_SP_ID}/appRoleAssignedTo" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${PRINCIPAL_ID}\",
      \"resourceId\": \"${GRAPH_SP_ID}\",
      \"appRoleId\": \"${ROLE_ID}\"
    }" \
    --output none && echo "    Done." || echo "    Already assigned or error — check manually."
}

assign_role "ThreatHunting.Read.All"
assign_role "Sites.ReadWrite.All"

echo ""
echo "==> Verifying assigned roles:"
az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${PRINCIPAL_ID}/appRoleAssignments" \
  --query "value[].{AppRoleId:appRoleId, ResourceDisplayName:resourceDisplayName}" \
  --output table

echo ""
echo "Done. Allow 1-5 minutes for Graph permissions to propagate before testing."
