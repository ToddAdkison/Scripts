# =============================================================================
# Validate-AzResourceMove.ps1
# Validates whether Azure resources can be moved to a target subscription/RG
# using Invoke-AzResourceAction -Action validateMoveResources
# =============================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Subscription ID containing the source resources")]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true, HelpMessage = "Source Resource Group name")]
    [string]$SourceResourceGroupName,

    [Parameter(Mandatory = $true, HelpMessage = "Target Resource Group resource ID")]
    [string]$TargetResourceGroupId,

    [Parameter(Mandatory = $false, HelpMessage = "Target Subscription ID (defaults to source if not provided)")]
    [string]$TargetSubscriptionId,

    [Parameter(Mandatory = $false, HelpMessage = "Specific resource IDs to validate (if empty, all resources in the RG are used)")]
    [string[]]$ResourceIds
)

# -----------------------------------------------------------------------------
# Helper: Write coloured status messages
# -----------------------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $colour = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $colour
}

# -----------------------------------------------------------------------------
# 1. Verify the Az module is available
# -----------------------------------------------------------------------------
Write-Status "Checking for Az.Resources module..."
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Status "Az.Resources module not found. Install with: Install-Module -Name Az -Scope CurrentUser" "ERROR"
    exit 1
}

Import-Module Az.Resources -ErrorAction Stop
Write-Status "Az.Resources module loaded." "SUCCESS"

# -----------------------------------------------------------------------------
# 2. Ensure an active Azure session exists
# -----------------------------------------------------------------------------
Write-Status "Verifying Azure login context..."
$context = Get-AzContext -ErrorAction SilentlyContinue

if (-not $context -or -not $context.Account) {
    Write-Status "No active Azure session found. Launching interactive login..." "WARNING"
    Connect-AzAccount -ErrorAction Stop
    $context = Get-AzContext
}

Write-Status "Logged in as: $($context.Account.Id)" "SUCCESS"

# -----------------------------------------------------------------------------
# 3. Set the source subscription context
# -----------------------------------------------------------------------------
Write-Status "Setting context to source subscription: $SourceSubscriptionId"
Set-AzContext -SubscriptionId $SourceSubscriptionId -ErrorAction Stop | Out-Null
Write-Status "Context set successfully." "SUCCESS"

# -----------------------------------------------------------------------------
# 4. Build the list of resource IDs to validate
# -----------------------------------------------------------------------------
if (-not $ResourceIds -or $ResourceIds.Count -eq 0) {
    Write-Status "No specific resources provided — retrieving all resources in '$SourceResourceGroupName'..."
    $resources = Get-AzResource -ResourceGroupName $SourceResourceGroupName -ErrorAction Stop

    if (-not $resources -or $resources.Count -eq 0) {
        Write-Status "No resources found in resource group '$SourceResourceGroupName'." "WARNING"
        exit 0
    }

    $ResourceIds = $resources | Select-Object -ExpandProperty ResourceId
    Write-Status "Found $($ResourceIds.Count) resource(s) to validate." "SUCCESS"
}
else {
    Write-Status "Using $($ResourceIds.Count) explicitly provided resource ID(s)."
}

# -----------------------------------------------------------------------------
# 5. Resolve the target subscription
# -----------------------------------------------------------------------------
if (-not $TargetSubscriptionId) {
    $TargetSubscriptionId = $SourceSubscriptionId
    Write-Status "No target subscription specified — defaulting to source subscription." "WARNING"
}

# -----------------------------------------------------------------------------
# 6. Build the request payload
# -----------------------------------------------------------------------------
$movePayload = @{
    resources           = @($ResourceIds)
    targetResourceGroup = $TargetResourceGroupId
}

Write-Status "Validation payload:"
Write-Host ($movePayload | ConvertTo-Json -Depth 5) -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# 7. Build the source Resource Group resource ID (needed by the cmdlet)
# -----------------------------------------------------------------------------
$sourceRgResourceId = "/subscriptions/$SourceSubscriptionId/resourceGroups/$SourceResourceGroupName"

# -----------------------------------------------------------------------------
# 8. Invoke the validation action
# -----------------------------------------------------------------------------
Write-Status "Invoking validateMoveResources action — this may take up to 15 minutes for large moves..."

try {
    $result = Invoke-AzResourceAction `
        -ResourceId    $sourceRgResourceId `
        -Action        "validateMoveResources" `
        -Parameters    $movePayload `
        -ApiVersion    "2021-04-01" `
        -Force `
        -ErrorAction   Stop

    # A 204 No Content response means the validation passed with no issues.
    Write-Status "Validation completed successfully — all resources are eligible to move." "SUCCESS"
    Write-Output $result
}
catch {
    $errMsg = $_.Exception.Message

    # Parse the inner error body if present
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        try {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            Write-Status "Validation FAILED. Azure error details:" "ERROR"

            # Surface each per-resource error
            if ($errBody.error.details) {
                foreach ($detail in $errBody.error.details) {
                    Write-Host "  Resource : $($detail.target)"   -ForegroundColor Red
                    Write-Host "  Code     : $($detail.code)"     -ForegroundColor Red
                    Write-Host "  Message  : $($detail.message)"  -ForegroundColor Red
                    Write-Host ""
                }
            }
            else {
                Write-Host "  Code    : $($errBody.error.code)"    -ForegroundColor Red
                Write-Host "  Message : $($errBody.error.message)" -ForegroundColor Red
            }
        }
        catch {
            Write-Status "Validation FAILED. Raw error: $errMsg" "ERROR"
        }
    }
    else {
        Write-Status "Validation FAILED. Error: $errMsg" "ERROR"
    }

    exit 1
}

# -----------------------------------------------------------------------------
# 9. Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Status "--- Validation Summary ---" "INFO"
Write-Host "  Source Subscription : $SourceSubscriptionId"
Write-Host "  Source Resource Group: $SourceResourceGroupName"
Write-Host "  Target Resource Group: $TargetResourceGroupId"
Write-Host "  Resources Validated  : $($ResourceIds.Count)"
Write-Host ""
Write-Status "Script completed." "SUCCESS"