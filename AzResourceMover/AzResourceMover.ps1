# =============================================================================
# AzResourceMover.ps1
#
# USAGE:
#   .\AzResourceMover.ps1 -Function Validate -SourceSubscriptionId <id> `
#       -SourceResourceGroupName <rg> -TargetResourceGroupId <id>
#
#   .\AzResourceMover.ps1 -Function Move -SourceSubscriptionId <id> `
#       -SourceResourceGroupName <rg> -TargetResourceGroupId <id>
#
#   .\AzResourceMover.ps1 -Function Copy -SourceSubscriptionId <id> `
#       -SourceResourceGroupName <rg> [-OutputPath .\MyExport]
#
# FUNCTIONS:
#   Validate  - Validates resources are eligible for a move (no changes made)
#   Move      - Validates then moves resources to the target resource group
#   Copy      - Exports resource group as ARM JSON and decompiles to Bicep
# =============================================================================

[CmdletBinding()]
param (
    # ---- Which function to run ----
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("Validate", "Move", "Copy")]
    [string]$Function,

    # ---- Shared parameters ----
    [Parameter(Mandatory = $true)]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$SourceResourceGroupName,

    # Required for Validate and Move; not needed for Copy
    [Parameter(Mandatory = $false)]
    [string]$TargetResourceGroupId,

    [Parameter(Mandatory = $false)]
    [string]$TargetSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string[]]$ResourceIds,

    # ---- Copy-specific parameters ----
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\AzExport",

    # Skip the confirmation prompt on Move (use in automation)
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# SHARED HELPERS
# =============================================================================

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $colour = switch ($Level) {
        "INFO"    { "Cyan"   }
        "SUCCESS" { "Green"  }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red"    }
        default   { "White"  }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $colour
}

function Write-Banner {
    param([string]$Title)
    $line = "-" * ($Title.Length + 6)
    Write-Host ""
    Write-Host $line            -ForegroundColor DarkGray
    Write-Host "   $Title   "  -ForegroundColor White
    Write-Host $line            -ForegroundColor DarkGray
    Write-Host ""
}

function Assert-Module {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Status "$ModuleName module not found. Install with: Install-Module -Name Az -Scope CurrentUser" "ERROR"
        exit 1
    }
    Import-Module $ModuleName -ErrorAction Stop
}

function Connect-IfNeeded {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) {
        Write-Status "No active Azure session found. Launching interactive login..." "WARNING"
        Connect-AzAccount -ErrorAction Stop
    }
    else {
        Write-Status "Logged in as: $((Get-AzContext).Account.Id)" "SUCCESS"
    }
}

# Returns $true if a resource ID is top-level (not a child resource).
# Top-level: .../providers/Namespace/Type/Name  (3 segments after 'providers')
# Child    : .../providers/Namespace/Type/Name/SubType/SubName  (5+ segments)
function Test-IsTopLevelResource {
    param([string]$ResourceId)
    $parts        = $ResourceId.ToLower() -split '/'
    $providerIdx  = [Array]::IndexOf($parts, 'providers')
    if ($providerIdx -lt 0) { return $false }
    return ($parts.Count - $providerIdx - 1) -le 3
}

# Retrieves and filters the resource list to top-level resources only.
function Get-TopLevelResourceIds {
    param(
        [string]   $SubscriptionId,
        [string]   $ResourceGroupName,
        [string[]] $ExplicitIds
    )

    if (-not $ExplicitIds -or $ExplicitIds.Count -eq 0) {
        Write-Status "Retrieving all resources in '$ResourceGroupName'..."
        $all = Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        if (-not $all -or $all.Count -eq 0) {
            Write-Status "No resources found in '$ResourceGroupName'." "WARNING"
            return @()
        }
        $ids = $all | Select-Object -ExpandProperty ResourceId
    }
    else {
        $ids = $ExplicitIds
    }

    $topLevel = @($ids | Where-Object { Test-IsTopLevelResource $_ })
    $skipped  = $ids.Count - $topLevel.Count

    if ($skipped -gt 0) {
        Write-Status "$skipped child resource(s) excluded (moved automatically with their parent)." "WARNING"
        $ids | Where-Object { -not (Test-IsTopLevelResource $_) } |
            ForEach-Object { Write-Host "  Skipped (child): $_" -ForegroundColor DarkYellow }
    }

    Write-Status "$($topLevel.Count) top-level resource(s) identified." "SUCCESS"
    return $topLevel
}

# =============================================================================
# FUNCTION: VALIDATE
# Calls validateMoveResources against the source RG. No resources are moved.
# =============================================================================

function Invoke-Validate {
    param(
        [string]   $SubscriptionId,
        [string]   $ResourceGroupName,
        [string]   $TargetRgId,
        [string]   $TargetSubId,
        [string[]] $ResourceIds
    )

    Write-Banner "VALIDATE"

    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Status "Context set to subscription: $SubscriptionId" "SUCCESS"

    $ids = Get-TopLevelResourceIds -SubscriptionId $SubscriptionId `
                                   -ResourceGroupName $ResourceGroupName `
                                   -ExplicitIds $ResourceIds
    if ($ids.Count -eq 0) { return $false }

    # Build the JSON body manually so the 'resources' property serializes as a
    # flat string array. Invoke-AzResourceAction serializes hashtables internally
    # and can wrap nested arrays in an extra object layer, causing the
    # "Unexpected character encountered while parsing value: {" error.
    $bodyObj = [ordered]@{
        resources           = [array]$ids
        targetResourceGroup = $TargetRgId
    }
    $jsonBody = $bodyObj | ConvertTo-Json -Depth 5 -Compress

    Write-Status "Payload preview:"
    Write-Host ($bodyObj | ConvertTo-Json -Depth 5) -ForegroundColor DarkGray

    # REST path for validateMoveResources
    $apiPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/" +
               "validateMoveResources?api-version=2021-04-01"

    Write-Status "Calling validateMoveResources - this can take up to 15 minutes..."

    try {
        $response = Invoke-AzRestMethod `
            -Path    $apiPath `
            -Method  POST `
            -Payload $jsonBody `
            -ErrorAction Stop

        # 202 = Accepted (async), 204 = No Content (sync pass) - both mean success
        if ($response.StatusCode -in @(202, 204)) {
            Write-Status "Validation PASSED - all resources are eligible to move." "SUCCESS"
            return $true
        }

        # Any other status code is treated as a failure; parse the error body
        $errBody = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        Write-Status "Validation FAILED. HTTP $($response.StatusCode)." "ERROR"

        if ($errBody.error.details) {
            foreach ($d in $errBody.error.details) {
                Write-Host "  Resource : $($d.target)"  -ForegroundColor Red
                Write-Host "  Code     : $($d.code)"    -ForegroundColor Red
                Write-Host "  Message  : $($d.message)" -ForegroundColor Red
                Write-Host ""
            }
        }
        elseif ($errBody.error) {
            Write-Host "  Code    : $($errBody.error.code)"    -ForegroundColor Red
            Write-Host "  Message : $($errBody.error.message)" -ForegroundColor Red
        }
        else {
            Write-Host $response.Content -ForegroundColor Red
        }
        return $false
    }
    catch {
        Write-Status "Validation request failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# =============================================================================
# FUNCTION: MOVE
# Runs Validate first. On success, prompts for confirmation then moves resources
# using Move-AzResource.
# =============================================================================

function Invoke-Move {
    param(
        [string]   $SubscriptionId,
        [string]   $ResourceGroupName,
        [string]   $TargetRgId,
        [string]   $TargetSubId,
        [string[]] $ResourceIds,
        [bool]     $ForceMove
    )

    Write-Banner "MOVE"

    # Always validate before moving
    Write-Status "Running pre-move validation..."
    $valid = Invoke-Validate -SubscriptionId   $SubscriptionId `
                             -ResourceGroupName $ResourceGroupName `
                             -TargetRgId        $TargetRgId `
                             -TargetSubId       $TargetSubId `
                             -ResourceIds       $ResourceIds
    if (-not $valid) {
        Write-Status "Move aborted - validation failed. Resolve the errors above and retry." "ERROR"
        exit 1
    }

    # Re-fetch the filtered ID list for the actual move
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $ids = Get-TopLevelResourceIds -SubscriptionId $SubscriptionId `
                                   -ResourceGroupName $ResourceGroupName `
                                   -ExplicitIds $ResourceIds

    # Parse target RG name and subscription from the target resource ID
    # Expected format: /subscriptions/<subId>/resourceGroups/<rgName>
    $targetParts  = $TargetRgId -split '/'
    $targetRgName = $targetParts[-1]
    $targetSubId  = if ($TargetSubId) { $TargetSubId } else {
                        $targetParts | Select-Object -Index 2
                    }

    Write-Host ""
    Write-Host "  Source RG     : $ResourceGroupName ($SubscriptionId)" -ForegroundColor White
    Write-Host "  Target RG     : $targetRgName ($targetSubId)"         -ForegroundColor White
    Write-Host "  Resources     : $($ids.Count)"                        -ForegroundColor White
    Write-Host ""

    if (-not $ForceMove) {
        $confirm = Read-Host "Proceed with move? This cannot be undone. [yes/NO]"
        if ($confirm -ne "yes") {
            Write-Status "Move cancelled by user." "WARNING"
            exit 0
        }
    }

    Write-Status "Moving $($ids.Count) resource(s)..."

    try {
        $moveParams = @{
            ResourceId                  = $ids
            DestinationResourceGroupName = $targetRgName
            ErrorAction                 = "Stop"
        }
        if ($targetSubId -and $targetSubId -ne $SubscriptionId) {
            $moveParams["DestinationSubscriptionId"] = $targetSubId
        }

        Move-AzResource @moveParams -Force:$ForceMove

        Write-Status "Move completed successfully." "SUCCESS"
    }
    catch {
        Write-Status "Move failed: $($_.Exception.Message)" "ERROR"
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message -ForegroundColor Red
        }
        exit 1
    }
}

# =============================================================================
# FUNCTION: COPY
# Exports the resource group as an ARM template (JSON) then decompiles it to
# Bicep using the Azure CLI (az bicep decompile).
# Output: $OutputPath\<resourceGroupName>.json + <resourceGroupName>.bicep
# =============================================================================

function Invoke-Copy {
    param(
        [string]   $SubscriptionId,
        [string]   $ResourceGroupName,
        [string[]] $ResourceIds,
        [string]   $OutputDir
    )

    Write-Banner "COPY (EXPORT TO BICEP)"

    # Ensure output directory exists
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        Write-Status "Created output directory: $OutputDir" "SUCCESS"
    }
    $OutputDir = (Resolve-Path $OutputDir).Path

    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Status "Context set to subscription: $SubscriptionId" "SUCCESS"

    # ---- Step 1: Export ARM template ----
    $jsonFile = Join-Path $OutputDir "$ResourceGroupName.json"
    Write-Status "Exporting ARM template for '$ResourceGroupName'..."

    try {
        $exportParams = @{
            ResourceGroupName         = $ResourceGroupName
            Path                      = $jsonFile
            IncludeParameterDefaultValue = $true
            SkipResourceNameEscaping  = $true
            Force                     = $true
            ErrorAction               = "Stop"
        }

        # If specific resource IDs were provided, scope the export to those resources
        if ($ResourceIds -and $ResourceIds.Count -gt 0) {
            $ids = Get-TopLevelResourceIds -SubscriptionId $SubscriptionId `
                                           -ResourceGroupName $ResourceGroupName `
                                           -ExplicitIds $ResourceIds
            if ($ids.Count -gt 0) {
                $exportParams["Resource"] = $ids
            }
        }

        Export-AzResourceGroup @exportParams | Out-Null
        Write-Status "ARM template exported to: $jsonFile" "SUCCESS"
    }
    catch {
        Write-Status "Export failed: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    # ---- Step 2: Decompile ARM JSON to Bicep ----
    Write-Status "Checking for Azure CLI and Bicep..."

    $azCli = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCli) {
        Write-Status "Azure CLI ('az') not found in PATH. Install from https://aka.ms/installazurecliwindows to enable Bicep decompilation." "WARNING"
        Write-Status "ARM template is available at: $jsonFile" "INFO"
        return
    }

    # Ensure bicep is installed via az CLI
    $bicepCheck = az bicep version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Bicep not installed. Installing via Azure CLI..." "WARNING"
        az bicep install 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Status "Bicep installation failed. ARM template is still available at: $jsonFile" "WARNING"
            return
        }
        Write-Status "Bicep installed successfully." "SUCCESS"
    }
    else {
        Write-Status "Bicep found: $($bicepCheck -join '')" "SUCCESS"
    }

    $bicepFile = [System.IO.Path]::ChangeExtension($jsonFile, ".bicep")
    Write-Status "Decompiling ARM template to Bicep..."

    az bicep decompile --file $jsonFile 2>&1 | ForEach-Object {
        Write-Host "  [az] $_" -ForegroundColor DarkGray
    }

    if ($LASTEXITCODE -eq 0 -and (Test-Path $bicepFile)) {
        Write-Status "Bicep file created: $bicepFile" "SUCCESS"
    }
    else {
        Write-Status "Decompilation produced warnings or errors. Check the output above." "WARNING"
        Write-Status "ARM template is still available at: $jsonFile" "INFO"
    }

    # ---- Step 3: Summary ----
    Write-Host ""
    Write-Status "--- Export Summary ---" "INFO"
    Write-Host "  Output directory : $OutputDir"
    Get-ChildItem -Path $OutputDir | ForEach-Object {
        Write-Host "  $($_.Name)  ($([math]::Round($_.Length / 1KB, 1)) KB)" -ForegroundColor Green
    }
}

# =============================================================================
# ENTRY POINT - Validate shared prerequisites then dispatch to the right function
# =============================================================================

Write-Banner "AzResourceMover | Function: $Function"

Assert-Module "Az.Resources"
Connect-IfNeeded

# Enforce required parameters per function
if ($Function -in @("Validate", "Move")) {
    if (-not $TargetResourceGroupId) {
        Write-Status "-TargetResourceGroupId is required for the $Function function." "ERROR"
        exit 1
    }
    if (-not $TargetSubscriptionId) {
        $TargetSubscriptionId = $SourceSubscriptionId
        Write-Status "No -TargetSubscriptionId provided - defaulting to source subscription." "WARNING"
    }
}

switch ($Function) {
    "Validate" {
        Invoke-Validate -SubscriptionId    $SourceSubscriptionId `
                        -ResourceGroupName $SourceResourceGroupName `
                        -TargetRgId        $TargetResourceGroupId `
                        -TargetSubId       $TargetSubscriptionId `
                        -ResourceIds       $ResourceIds
    }
    "Move" {
        Invoke-Move     -SubscriptionId    $SourceSubscriptionId `
                        -ResourceGroupName $SourceResourceGroupName `
                        -TargetRgId        $TargetResourceGroupId `
                        -TargetSubId       $TargetSubscriptionId `
                        -ResourceIds       $ResourceIds `
                        -ForceMove         $Force.IsPresent
    }
    "Copy" {
        Invoke-Copy     -SubscriptionId    $SourceSubscriptionId `
                        -ResourceGroupName $SourceResourceGroupName `
                        -ResourceIds       $ResourceIds `
                        -OutputDir         $OutputPath
    }
}