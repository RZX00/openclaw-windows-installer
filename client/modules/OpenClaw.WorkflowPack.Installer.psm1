Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WorkflowPackReadinessLabel {
    param([string]$Status)

    switch ("$Status") {
        'ready' { return 'Ready' }
        'needs-setup' { return 'Needs Setup' }
        default { return 'Needs Repair' }
    }
}

function New-WorkflowPackDefaultReadiness {
    param([string]$Summary = 'Workflow pack verification did not complete.')

    return [pscustomobject]@{
        status                   = 'needs-repair'
        state                    = 'Needs Repair'
        summary                  = $Summary
        unresolvedRequiredSkills = @()
        integrityIssues          = @()
        provisioningFailures     = @()
        blockingPrerequisites    = @()
        warningPrerequisites     = @()
    }
}

function Test-WorkflowPackOperationSuccess {
    param([object]$Readiness)

    if ($null -eq $Readiness) {
        return $false
    }

    return ("$($Readiness.status)" -ne 'needs-repair')
}

function Get-WorkflowPackReadinessState {
    param(
        [object[]]$RequiredSourceFailures = @(),
        [object[]]$ProvisioningResults = @(),
        [object[]]$PrerequisiteResults = @(),
        [object[]]$IntegrityIssues = @(),
        [string]$ReadySummary = 'Workflow pack is installed and ready.',
        [string]$NeedsSetupSummary = 'Workflow pack payload is installed, but one or more manual setup steps are still required.',
        [string]$NeedsRepairSummary = 'Workflow pack install completed, but verification found drift or missing assets that need repair.'
    )

    $failedPrerequisites = @(@($PrerequisiteResults) | Where-Object { -not $_.success })
    $blockingPrereqs = @($failedPrerequisites | Where-Object { $_.severity -eq 'error' })
    $warningPrereqs = @($failedPrerequisites | Where-Object { $_.severity -ne 'error' })
    $manualOutstanding = @($failedPrerequisites | Where-Object { $_.manual })
    $automatedFailures = @($failedPrerequisites | Where-Object { -not $_.manual })
    $provisioningFailures = @(@($ProvisioningResults) | Where-Object { -not $_.success })
    $integrityItems = @($IntegrityIssues)
    $requiredSourceItems = @($RequiredSourceFailures)

    $status = if ($requiredSourceItems.Count -gt 0 -or $provisioningFailures.Count -gt 0 -or $automatedFailures.Count -gt 0 -or $integrityItems.Count -gt 0) {
        'needs-repair'
    } elseif ($manualOutstanding.Count -gt 0) {
        'needs-setup'
    } else {
        'ready'
    }

    $summary = switch ($status) {
        'ready' { $ReadySummary }
        'needs-setup' { $NeedsSetupSummary }
        default { $NeedsRepairSummary }
    }

    return [pscustomobject]@{
        status                   = $status
        state                    = (Get-WorkflowPackReadinessLabel -Status $status)
        summary                  = $summary
        unresolvedRequiredSkills = @($requiredSourceItems)
        integrityIssues          = @($integrityItems)
        provisioningFailures     = @($provisioningFailures)
        blockingPrerequisites    = @($blockingPrereqs)
        warningPrerequisites     = @($warningPrereqs)
    }
}

Export-ModuleMember -Function @(
    'Get-WorkflowPackReadinessLabel',
    'New-WorkflowPackDefaultReadiness',
    'Test-WorkflowPackOperationSuccess',
    'Get-WorkflowPackReadinessState'
)
