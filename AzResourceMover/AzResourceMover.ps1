<#
.SYNOPSIS
    Checks resource dependencies and validates Azure resources eligible for
    move between resource groups and/or subscriptions.

.DESCRIPTION
    Gathers all resource IDs from a source resource group, inspects locks,
    cross-group dependencies, naming conflicts, then calls the Azure
    validateMoveResources API. Built using functional programming principles:
    pure functions, pipeline composition, and no shared mutable state.

.PARAMETER SourceSubscriptionId
    The subscription ID containing the source resources.

.PARAMETER SourceResourceGroupName
    The name of the source resource group.

.PARAMETER TargetResourceGroupName
    The name of the target resource group.

.PARAMETER TargetSubscriptionId
    The target subscription ID. Defaults to SourceSubscriptionId if omitted.

.PARAMETER ResourceIds
    Optional. Specific resource IDs to evaluate. If omitted, all resources
    in the source resource group are used.

.PARAMETER SkipDependencyCheck
    Skip the cross-group dependency and lock analysis (faster, validate only).

.PARAMETER OutputPath
    Optional file path to write the full report as a JSON file.

.PARAMETER Move
    When included, validates resources first and then executes the move if all
    checks pass. Without this switch the script validates only and makes no
    changes to your environment.

.EXAMPLE
    # Validate only - no resources are moved
    .\AzResourceMover.ps1 `
        -SourceSubscriptionId    "aaaa-bbbb-cccc-dddd" `
        -SourceResourceGroupName "my-source-rg" `
        -TargetResourceGroupName "my-target-rg"

.EXAMPLE
    # Validate then move across subscriptions
    .\AzResourceMover.ps1 `
        -SourceSubscriptionId    "aaaa-bbbb-cccc-dddd" `
        -SourceResourceGroupName "my-source-rg" `
        -TargetSubscriptionId    "eeee-ffff-gggg-hhhh" `
        -TargetResourceGroupName "my-target-rg" `
        -Move

.EXAMPLE
    # Validate then move, skipping dependency checks
    .\AzResourceMover.ps1 `
        -SourceSubscriptionId    "aaaa-bbbb-cccc-dddd" `
        -SourceResourceGroupName "my-source-rg" `
        -TargetResourceGroupName "my-target-rg" `
        -SkipDependencyCheck `
        -Move
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$SourceResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$TargetResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TargetSubscriptionId = $SourceSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string[]]$ResourceIds = @(),

    [Parameter(Mandatory = $false)]
    [switch]$SkipDependencyCheck,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$Move
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# ==============================================================================
# SECTION 1 - OUTPUT HELPERS
# Pure functions: accept input, write to host, return nothing.
# ==============================================================================

function Write-Header {
    param([string]$Title)
    $bar = "=" * 70
    Write-Host ""
    Write-Host $bar                -ForegroundColor DarkCyan
    Write-Host "  $Title"         -ForegroundColor Cyan
    Write-Host $bar                -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "-- $Title $("-" * [Math]::Max(0, 65 - $Title.Length))" -ForegroundColor DarkGray
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $colour = switch ($Level) {
        "INFO"   { "Cyan"     }
        "OK"     { "Green"    }
        "WARN"   { "Yellow"   }
        "ERROR"  { "Red"      }
        "DETAIL" { "DarkGray" }
        default  { "White"    }
    }
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $colour
}

# ==============================================================================
# SECTION 2 - PREREQUISITE CHECKS
# Pure functions: validate environment, return $true/$false.
# ==============================================================================

function Test-ModuleAvailable {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Log "$ModuleName is not installed. Run: Install-Module -Name Az -Scope CurrentUser" "ERROR"
        return $false
    }
    Import-Module $ModuleName -ErrorAction Stop
    return $true
}

function Test-AzureSession {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) {
        Write-Log "No active Azure session. Launching login..." "WARN"
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
    }
    Write-Log "Authenticated as: $($ctx.Account.Id)" "OK"
    return $true
}

function Test-ResourceGroupExists {
    param([string]$SubscriptionId, [string]$ResourceGroupName)
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Log "Resource group '$ResourceGroupName' not found in subscription '$SubscriptionId'." "ERROR"
        return $false
    }
    Write-Log "Resource group '$ResourceGroupName' confirmed." "OK"
    return $true
}

# ==============================================================================
# SECTION 3 - RESOURCE COLLECTION
# Pure functions: accept context, return resource objects.
# ==============================================================================

# Returns all raw Az resource objects from the source resource group.
function Get-SourceResources {
    param([string]$SubscriptionId, [string]$ResourceGroupName)
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $resources = Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    Write-Log "Found $($resources.Count) total resource(s) in '$ResourceGroupName'." "OK"
    return $resources
}

# Pure predicate: returns $true if a resource ID belongs to a top-level resource.
# Top-level IDs have exactly 3 segments after /providers/ (namespace/type/name).
# Child resources add extra type/name pairs (5, 7 ... segments) and move
# automatically with their parent so must be excluded from the request.
function Test-IsTopLevel {
    param([string]$ResourceId)
    $parts       = $ResourceId.ToLower() -split '/'
    $providerIdx = [Array]::IndexOf($parts, 'providers')
    return ($providerIdx -ge 0 -and ($parts.Count - $providerIdx - 1) -le 3)
}

# Pure filter: returns only top-level resources.
function Select-TopLevelResources {
    param([object[]]$Resources)

    $top     = @($Resources | Where-Object { Test-IsTopLevel $_.ResourceId })
    $skipped = $Resources.Count - $top.Count

    if ($skipped -gt 0) {
        Write-Log "$skipped child resource(s) excluded (auto-moved with their parent)." "WARN"
        $Resources |
            Where-Object { -not (Test-IsTopLevel $_.ResourceId) } |
            ForEach-Object { Write-Log "  Child excluded: $($_.ResourceId)" "DETAIL" }
    }

    Write-Log "$($top.Count) top-level resource(s) will be evaluated." "OK"
    return $top
}

# Resolves the final evaluated resource list from either explicit IDs or the
# full source resource group, then filters to top-level only.
function Resolve-ResourceIds {
    param(
        [string]   $SubscriptionId,
        [string]   $ResourceGroupName,
        [string[]] $ExplicitIds
    )

    $all = Get-SourceResources -SubscriptionId    $SubscriptionId `
                               -ResourceGroupName $ResourceGroupName

    $scoped = if ($ExplicitIds -and $ExplicitIds.Count -gt 0) {
        $all | Where-Object { $_.ResourceId -in $ExplicitIds }
    } else {
        $all
    }

    return Select-TopLevelResources -Resources @($scoped)
}

# ==============================================================================
# SECTION 4 - DEPENDENCY CHECKS
# Pure functions: accept resource data, return structured result objects.
# ==============================================================================

# Checks each resource for management locks (ReadOnly or CanNotDelete).
# A locked resource cannot be moved until the lock is removed.
function Get-ResourceLockStatus {
    param([object[]]$Resources)

    $Resources | ForEach-Object {
        $res   = $_
        $locks = Get-AzResourceLock `
                    -ResourceGroupName $res.ResourceGroupName `
                    -ResourceName      $res.Name `
                    -ResourceType      $res.ResourceType `
                    -ErrorAction       SilentlyContinue

        [PSCustomObject]@{
            ResourceId   = $res.ResourceId
            ResourceName = $res.Name
            ResourceType = $res.ResourceType
            HasLock      = ($null -ne $locks -and @($locks).Count -gt 0)
            LockNames    = if ($locks) { @($locks) | Select-Object -ExpandProperty Name }       else { @() }
            LockTypes    = if ($locks) { @($locks) | ForEach-Object { $_.Properties.level } }  else { @() }
        }
    }
}

# Exports the source resource group as an ARM template and inspects dependsOn
# arrays for references that point outside the source resource group.
# Resources with external dependencies may fail or behave unexpectedly after move.
function Get-CrossGroupDependencies {
    param(
        [string]   $ResourceGroupName,
        [string[]] $SourceResourceIds
    )

    Write-Log "Exporting ARM template to map dependencies..." "INFO"
    $tempFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.json')

    try {
        Export-AzResourceGroup `
            -ResourceGroupName $ResourceGroupName `
            -Path              $tempFile `
            -Force `
            -ErrorAction Stop | Out-Null

        $template      = Get-Content $tempFile -Raw | ConvertFrom-Json
        $sourceIdLower = $SourceResourceIds | ForEach-Object { $_.ToLower() }

        # Cast to [array] before piping so ForEach-Object always receives a
        # collection. With Set-StrictMode -Version Latest, piping a single
        # PSCustomObject causes a PropertyNotFoundException on .Count.
        [array]$templateResources = if ($template.PSObject.Properties.Name -contains 'resources' -and
                                         $null -ne $template.resources) {
            @($template.resources)
        } else { @() }

        if ($templateResources.Count -eq 0) {
            Write-Log 'ARM template contained no resources to inspect.' 'WARN'
            return @()
        }

        foreach ($resource in $templateResources) {
            [array]$deps = if ($resource.PSObject.Properties.Name -contains 'dependsOn' -and
                                $null -ne $resource.dependsOn) {
                                @($resource.dependsOn)
                            } else { @() }

            [array]$externalDeps = @($deps | Where-Object {
                $_ -match '/subscriptions/' -and $_.ToLower() -notin $sourceIdLower
            })

            [PSCustomObject]@{
                ResourceName         = $resource.name
                ResourceType         = $resource.type
                TotalDependencies    = @($deps).Count
                ExternalDependencies = $externalDeps
                HasExternalDeps      = ($externalDeps.Count -gt 0)
            }
        }
    }
    finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
}

# Checks whether the target resource group already has resources with the same
# name and type as the source resources, which would cause a move conflict.
function Get-NamingConflicts {
    param(
        [string]   $TargetSubscriptionId,
        [string]   $TargetResourceGroupName,
        [object[]] $SourceResources
    )

    Set-AzContext -SubscriptionId $TargetSubscriptionId | Out-Null
    $targetResources = @(Get-AzResource -ResourceGroupName $TargetResourceGroupName `
                                        -ErrorAction SilentlyContinue)

    $conflicts = $SourceResources | Where-Object {
        $src = $_
        $targetResources | Where-Object {
            $_.Name -eq $src.Name -and $_.ResourceType -eq $src.ResourceType
        }
    } | ForEach-Object {
        [PSCustomObject]@{
            ResourceName = $_.Name
            ResourceType = $_.ResourceType
            ResourceId   = $_.ResourceId
        }
    }

    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
    return @($conflicts)
}

# ==============================================================================
# SECTION 5 - AZURE API VALIDATION
# Calls validateMoveResources via Invoke-AzRestMethod.
# Body is serialized manually to guarantee 'resources' is a flat JSON array
# (Invoke-AzResourceAction -Parameters wraps arrays in an extra object layer).
# ==============================================================================

function Invoke-MoveValidation {
    param(
        [string]   $SourceSubscriptionId,
        [string]   $SourceResourceGroupName,
        [string]   $TargetSubscriptionId,
        [string]   $TargetResourceGroupName,
        [string[]] $ResourceIds
    )

    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

    $targetRgId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName"

    $body = [ordered]@{
        resources           = [array]$ResourceIds
        targetResourceGroup = $targetRgId
    } | ConvertTo-Json -Depth 5 -Compress

    $apiPath = "/subscriptions/$SourceSubscriptionId/resourceGroups/" +
               "$SourceResourceGroupName/validateMoveResources?api-version=2021-04-01"

    Write-Log "Calling validateMoveResources API (may take up to 15 minutes)..." "INFO"

    try {
        $response = Invoke-AzRestMethod -Path $apiPath -Method POST -Payload $body

        # 202 Accepted  = async validation queued (pass)
        # 204 No Content = sync validation passed
        $passed = $response.StatusCode -in @(202, 204)

        $errors = if (-not $passed -and $response.Content) {
            $errBody = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errBody.error.details) {
                @($errBody.error.details | ForEach-Object {
                    [PSCustomObject]@{ Resource = $_.target; Code = $_.code; Message = $_.message }
                })
            } elseif ($errBody.error) {
                @([PSCustomObject]@{ Resource = "N/A"; Code = $errBody.error.code; Message = $errBody.error.message })
            } else { @() }
        } else { @() }

        return [PSCustomObject]@{
            Passed     = $passed
            StatusCode = $response.StatusCode
            Errors     = $errors
        }
    }
    catch {
        return [PSCustomObject]@{
            Passed     = $false
            StatusCode = 0
            Errors     = @([PSCustomObject]@{
                Resource = "N/A"
                Code     = "RequestFailed"
                Message  = $_.Exception.Message
            })
        }
    }
}


# ==============================================================================
# SECTION 6 - MOVE EXECUTION
# Executes the resource move using Move-AzResource after validation has passed.
# Pure function: accepts all required context, returns a structured result.
# ==============================================================================

# Executes the move of validated top-level resources to the target resource group.
# Returns a result object with Succeeded, MovedCount, FailedResources, and Duration.
function Invoke-ResourceMove {
    param(
        [string]   $SourceSubscriptionId,
        [string]   $SourceResourceGroupName,
        [string]   $TargetSubscriptionId,
        [string]   $TargetResourceGroupName,
        [string[]] $ResourceIds
    )

    Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

    $failedResources = @()
    $startTime       = Get-Date

    Write-Log "Moving $($ResourceIds.Count) resource(s) to '$TargetResourceGroupName'..." "INFO"

    try {
        $moveParams = @{
            ResourceId                   = $ResourceIds
            DestinationResourceGroupName = $TargetResourceGroupName
            Force                        = $true
            ErrorAction                  = "Stop"
        }

        if ($TargetSubscriptionId -ne $SourceSubscriptionId) {
            $moveParams["DestinationSubscriptionId"] = $TargetSubscriptionId
            Write-Log "Cross-subscription move detected. Target subscription: $TargetSubscriptionId" "INFO"
        }

        Move-AzResource @moveParams | Out-Null

        $duration = (Get-Date) - $startTime

        return [PSCustomObject]@{
            Succeeded        = $true
            MovedCount       = $ResourceIds.Count
            FailedResources  = @()
            DurationSeconds  = [math]::Round($duration.TotalSeconds, 1)
            CompletedAt      = (Get-Date -Format "o")
        }
    }
    catch {
        $duration = (Get-Date) - $startTime

        # Attempt to identify which specific resource triggered the failure
        $failedResources = @([PSCustomObject]@{
            ResourceId = "See error message"
            Error      = $_.Exception.Message
        })

        return [PSCustomObject]@{
            Succeeded        = $false
            MovedCount       = 0
            FailedResources  = $failedResources
            DurationSeconds  = [math]::Round($duration.TotalSeconds, 1)
            CompletedAt      = (Get-Date -Format "o")
        }
    }
}

# Writes the move result to the console in the same style as Write-Report.
function Write-MoveResult {
    param([object]$MoveResult)

    Write-Section "MOVE RESULT"

    if ($MoveResult.Succeeded) {
        Write-Log "Move SUCCEEDED." "OK"
        Write-Log "  Resources moved : $($MoveResult.MovedCount)" "OK"
        Write-Log "  Duration        : $($MoveResult.DurationSeconds)s" "OK"
        Write-Log "  Completed at    : $($MoveResult.CompletedAt)" "OK"
    } else {
        Write-Log "Move FAILED after $($MoveResult.DurationSeconds)s." "ERROR"
        foreach ($failure in $MoveResult.FailedResources) {
            Write-Log "  Resource : $($failure.ResourceId)" "ERROR"
            Write-Log "  Error    : $($failure.Error)"      "ERROR"
        }
    }
    Write-Host ""
}

# ==============================================================================
# SECTION 7 - REPORT ASSEMBLY AND DISPLAY
# Pure functions: accept result data, produce a structured report object.
# ==============================================================================

function New-Report {
    param(
        [object[]]  $Resources,
        [object[]]  $LockResults,
        [object[]]  $DependencyResults,
        [object[]]  $ConflictResults,
        [object]    $ValidationResult,
        [hashtable] $RunConfig
    )

    $lockedResources   = @($LockResults       | Where-Object { $_.HasLock })
    $externalDepResources = @($DependencyResults | Where-Object { $_.HasExternalDeps })

    [PSCustomObject]@{
        GeneratedAt      = (Get-Date -Format "o")
        Configuration    = $RunConfig
        ResourceCount    = $Resources.Count
        Resources        = @($Resources | Select-Object Name, ResourceType, ResourceId, Location)
        LockedResources  = $lockedResources
        ExternalDeps     = $externalDepResources
        NamingConflicts  = @($ConflictResults)
        Validation       = $ValidationResult
        OverallPass      = (
            $ValidationResult.Passed        -and
            $lockedResources.Count      -eq 0 -and
            $externalDepResources.Count -eq 0 -and
            @($ConflictResults).Count   -eq 0
        )
    }
}

function Write-Report {
    param([object]$Report)

    Write-Section "RESOURCES COLLECTED ($($Report.ResourceCount))"
    $Report.Resources | ForEach-Object {
        Write-Log "$($_.ResourceType.PadRight(52)) $($_.Name)" "DETAIL"
    }

    Write-Section "LOCK CHECK"
    if ($Report.LockedResources.Count -eq 0) {
        Write-Log "No resource locks detected." "OK"
    } else {
        $Report.LockedResources | ForEach-Object {
            Write-Log "LOCKED: $($_.ResourceName)  [$($_.LockTypes -join ', ')]" "WARN"
            Write-Log "  Remove lock(s): $($_.LockNames -join ', ') before moving." "DETAIL"
        }
    }

    Write-Section "CROSS-GROUP DEPENDENCY CHECK"
    if ($Report.ExternalDeps.Count -eq 0) {
        Write-Log "No external dependencies detected." "OK"
    } else {
        $Report.ExternalDeps | ForEach-Object {
            Write-Log "EXTERNAL DEP: $($_.ResourceName) ($($_.ResourceType))" "WARN"
            $_.ExternalDependencies | ForEach-Object { Write-Log "  -> $_" "DETAIL" }
        }
    }

    Write-Section "NAMING CONFLICT CHECK"
    if ($Report.NamingConflicts.Count -eq 0) {
        Write-Log "No naming conflicts in the target resource group." "OK"
    } else {
        $Report.NamingConflicts | ForEach-Object {
            Write-Log "CONFLICT: '$($_.ResourceName)' ($($_.ResourceType)) already exists in target." "WARN"
        }
    }

    Write-Section "AZURE API VALIDATION"
    if ($Report.Validation.Passed) {
        Write-Log "Azure validation PASSED (HTTP $($Report.Validation.StatusCode))." "OK"
    } else {
        Write-Log "Azure validation FAILED (HTTP $($Report.Validation.StatusCode))." "ERROR"
        $Report.Validation.Errors | ForEach-Object {
            Write-Log "  Resource : $($_.Resource)" "ERROR"
            Write-Log "  Code     : $($_.Code)"     "ERROR"
            Write-Log "  Message  : $($_.Message)"  "ERROR"
        }
    }

    Write-Section "OVERALL RESULT"
    if ($Report.OverallPass) {
        Write-Log "ALL CHECKS PASSED - resources appear ready to move." "OK"
    } else {
        Write-Log "ONE OR MORE CHECKS FAILED - review warnings above before moving." "ERROR"
    }
    Write-Host ""
}

# ==============================================================================
# SECTION 8 - ENTRY POINT
# Composes the pipeline: prereqs -> collect -> check -> validate -> (move) -> report.
# ==============================================================================

Write-Header "AzResourceMover - Dependency Check and Move Validation"

# Announce mode clearly at the start so the operator knows what will happen
if ($Move) {
    Write-Log "Mode: VALIDATE + MOVE  (-Move switch is ON  - resources WILL be moved if validation passes)" "WARN"
} else {
    Write-Log "Mode: VALIDATE ONLY    (-Move switch is OFF - no resources will be moved)" "INFO"
}

# -- Prerequisites --
if (-not (Test-ModuleAvailable "Az.Resources")) { exit 1 }
if (-not (Test-AzureSession))                   { exit 1 }

Write-Section "VALIDATING RESOURCE GROUPS"
if (-not (Test-ResourceGroupExists -SubscriptionId    $SourceSubscriptionId `
                                   -ResourceGroupName $SourceResourceGroupName)) { exit 1 }

if (-not (Test-ResourceGroupExists -SubscriptionId    $TargetSubscriptionId `
                                   -ResourceGroupName $TargetResourceGroupName)) { exit 1 }

Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

# -- Collect resources --
Write-Section "COLLECTING RESOURCES"
$resources = Resolve-ResourceIds -SubscriptionId    $SourceSubscriptionId `
                                 -ResourceGroupName $SourceResourceGroupName `
                                 -ExplicitIds       $ResourceIds

if ($resources.Count -eq 0) {
    Write-Log "No resources to evaluate. Exiting." "WARN"
    exit 0
}

$resolvedIds = @($resources | Select-Object -ExpandProperty ResourceId)

# -- Dependency and lock checks --
$lockResults = @()
$depResults  = @()
$conflicts   = @()

if (-not $SkipDependencyCheck) {
    Write-Section "RUNNING DEPENDENCY CHECKS"

    Write-Log "Checking resource locks..." "INFO"
    $lockResults = @(Get-ResourceLockStatus -Resources $resources)

    Write-Log "Checking cross-group dependencies..." "INFO"
    $depResults = @(Get-CrossGroupDependencies -ResourceGroupName  $SourceResourceGroupName `
                                               -SourceResourceIds $resolvedIds)

    Write-Log "Checking for naming conflicts in target..." "INFO"
    $conflicts = @(Get-NamingConflicts -TargetSubscriptionId    $TargetSubscriptionId `
                                       -TargetResourceGroupName $TargetResourceGroupName `
                                       -SourceResources         $resources)
} else {
    Write-Log "Dependency checks skipped (-SkipDependencyCheck was set)." "WARN"
}

# -- Azure API validation --
$validationResult = Invoke-MoveValidation `
    -SourceSubscriptionId    $SourceSubscriptionId `
    -SourceResourceGroupName $SourceResourceGroupName `
    -TargetSubscriptionId    $TargetSubscriptionId `
    -TargetResourceGroupName $TargetResourceGroupName `
    -ResourceIds             $resolvedIds

# -- Assemble and display report --
$report = New-Report `
    -Resources         $resources `
    -LockResults       $lockResults `
    -DependencyResults $depResults `
    -ConflictResults   $conflicts `
    -ValidationResult  $validationResult `
    -RunConfig         @{
        SourceSubscriptionId    = $SourceSubscriptionId
        SourceResourceGroupName = $SourceResourceGroupName
        TargetSubscriptionId    = $TargetSubscriptionId
        TargetResourceGroupName = $TargetResourceGroupName
        SkipDependencyCheck     = $SkipDependencyCheck.IsPresent
    }

Write-Header "VALIDATION REPORT"
Write-Report -Report $report

# -- Execute move if -Move was supplied and all validation checks passed --
if ($Move) {
    if (-not $report.OverallPass) {
        Write-Log "Move SKIPPED - one or more validation checks failed. Resolve issues and retry." "ERROR"
        exit 1
    }

    Write-Header "EXECUTING MOVE"
    $moveResult = Invoke-ResourceMove `
        -SourceSubscriptionId    $SourceSubscriptionId `
        -SourceResourceGroupName $SourceResourceGroupName `
        -TargetSubscriptionId    $TargetSubscriptionId `
        -TargetResourceGroupName $TargetResourceGroupName `
        -ResourceIds             $resolvedIds

    Write-MoveResult -MoveResult $moveResult

    if (-not $moveResult.Succeeded) { exit 1 }
}

<# -- Optional JSON output --
if ($OutputPath) {
    $report | ConvertTo-Json -Depth 10 |
        Out-File -FilePath $OutputPath -Encoding UTF8 -Force
    Write-Log "Full report saved to: $OutputPath" "OK"
}

return $report
#>