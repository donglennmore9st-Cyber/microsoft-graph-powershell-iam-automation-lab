<#
.SYNOPSIS
    Microsoft Graph PowerShell IAM Automation Lab

.DESCRIPTION
    Sanitized portfolio version of hands-on IAM automation workflows:
    - Certificate-based Microsoft Graph authentication
    - CSV-based JML processing
    - JML input handling with Mover automation and Leaver access review
    - Group membership validation
    - Disabled-user and stale-access reporting
    - Directory audit retrieval
    - Reusable error handling

.NOTES
    Hands-on lab / production-style simulation.
    Replace placeholder values only in an authorized lab or tenant.
#>

# ============================================================
# 1. CONFIGURATION
# ============================================================

$TenantId              = "<TENANT-ID>"
$ClientId              = "<APP-CLIENT-ID>"
$CertificateThumbprint = "<CERTIFICATE-THUMBPRINT>"
$CsvPath               = "<PATH-TO-JML-INPUT.csv>"

# ============================================================
# 2. MICROSOFT GRAPH CONNECTION
# ============================================================

Connect-MgGraph `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -CertificateThumbprint $CertificateThumbprint `
    -NoWelcome

Get-MgContext

# ============================================================
# 3. IMPORT JML INPUT
# ============================================================

$jmlRows = Import-Csv $CsvPath

$jmlRows | Format-Table -AutoSize

$joinerRow = $jmlRows | Where-Object { $_.Action -eq "Joiner" }
$moverRow  = $jmlRows | Where-Object { $_.Action -eq "Mover" }
$leaverRow = $jmlRows | Where-Object { $_.Action -eq "Leaver" }

# ============================================================
# 4. REQUEST VALIDATION
# ============================================================

$moverValidation = [PSCustomObject]@{
    ActionValid        = ($moverRow.Action -eq "Mover")
    DisplayNamePresent = (-not [string]::IsNullOrWhiteSpace($moverRow.DisplayName))
    DepartmentPresent  = (-not [string]::IsNullOrWhiteSpace($moverRow.Department))
    TargetGroupPresent = (-not [string]::IsNullOrWhiteSpace($moverRow.TargetGroup))
}

$leaverValidation = [PSCustomObject]@{
    ActionValid        = ($leaverRow.Action -eq "Leaver")
    DisplayNamePresent = (-not [string]::IsNullOrWhiteSpace($leaverRow.DisplayName))
    DepartmentPresent  = (-not [string]::IsNullOrWhiteSpace($leaverRow.Department))
    TargetGroupPresent = (-not [string]::IsNullOrWhiteSpace($leaverRow.TargetGroup))
}

$moverValidation  | Format-List
$leaverValidation | Format-List

# ============================================================
# 5. MOVER BASELINE
# ============================================================

$moverUser = Get-MgUser `
    -Filter "displayName eq '$($moverRow.DisplayName)'" `
    -Property DisplayName,UserPrincipalName,Id,AccountEnabled,Department

$moverUser |
    Select-Object DisplayName,UserPrincipalName,Id,AccountEnabled,Department |
    Format-List

$salesGroup = Get-MgGroup `
    -Filter "displayName eq '$($moverRow.TargetGroup)'"

$financeGroup = Get-MgGroup `
    -Filter "displayName eq 'SG_Finance_Users'"

$salesGroup |
    Select-Object DisplayName,Id,SecurityEnabled,MailEnabled |
    Format-List

$financeGroup |
    Select-Object DisplayName,Id,SecurityEnabled,MailEnabled |
    Format-List

# ============================================================
# 6. MOVER ACCESS CHECK
# ============================================================

$salesBefore = Get-MgGroupMember `
    -GroupId $salesGroup.Id `
    -All |
    Where-Object { $_.Id -eq $moverUser.Id }

$financeBefore = Get-MgGroupMember `
    -GroupId $financeGroup.Id `
    -All |
    Where-Object { $_.Id -eq $moverUser.Id }

# ============================================================
# 7. MOVER CHANGE
# ============================================================

Update-MgUser `
    -UserId $moverUser.Id `
    -Department $moverRow.Department

Remove-MgGroupMemberByRef `
    -GroupId $financeGroup.Id `
    -DirectoryObjectId $moverUser.Id

$memberOdataId = "https://graph.microsoft.com/v1.0/directoryObjects/$($moverUser.Id)"

New-MgGroupMemberByRef `
    -GroupId $salesGroup.Id `
    -OdataId $memberOdataId

# ============================================================
# 8. MOVER VERIFICATION
# ============================================================

$moverUserAfterDepartment = Get-MgUser `
    -UserId $moverUser.Id `
    -Property DisplayName,UserPrincipalName,Id,AccountEnabled,Department

$salesAfter = Get-MgGroupMember `
    -GroupId $salesGroup.Id `
    -All |
    Where-Object { $_.Id -eq $moverUser.Id }

$financeAfter = Get-MgGroupMember `
    -GroupId $financeGroup.Id `
    -All |
    Where-Object { $_.Id -eq $moverUser.Id }

[PSCustomObject]@{
    User                    = $moverUser.DisplayName
    DepartmentAfter         = $moverUserAfterDepartment.Department
    FinanceMembershipBefore = ($financeBefore -ne $null)
    FinanceMembershipAfter  = ($financeAfter -ne $null)
    SalesMembershipBefore   = ($salesBefore -ne $null)
    SalesMembershipAfter    = ($salesAfter -ne $null)
} | Format-List

# ============================================================
# 9. DISABLED-USER ACCESS REVIEW
# ============================================================

$disabledUsers = Get-MgUser `
    -All `
    -Property DisplayName,Id,AccountEnabled,Department |
    Where-Object { $_.AccountEnabled -eq $false }

$disabledAccessReview = foreach ($user in $disabledUsers) {

    $groups = @(
        Get-MgUserMemberOfAsGroup `
            -UserId $user.Id `
            -All
    )

    [PSCustomObject]@{
        DisplayName           = $user.DisplayName
        AccountEnabled        = $user.AccountEnabled
        Department            = $user.Department
        RemainingDirectGroups = $groups.Count
        ReviewStatus          = if ($groups.Count -gt 0) {
                                    "Review Required"
                                }
                                else {
                                    "Clean"
                                }
    }
}

$disabledAccessReview | Format-Table -AutoSize

# ============================================================
# 10. REUSABLE GRAPH QUERY WRAPPER
# ============================================================

function Invoke-GraphQuerySafe {

    param(
        [Parameter(Mandatory)]
        [string]$QueryName,

        [Parameter(Mandatory)]
        [scriptblock]$Operation
    )

    try {

        $result = @(& $Operation)

        [PSCustomObject]@{
            Query       = $QueryName
            Status      = "Success"
            RecordCount = $result.Count
            Detail      = "Operation completed successfully"
        }
    }
    catch {

        [PSCustomObject]@{
            Query       = $QueryName
            Status      = "Handled"
            RecordCount = 0
            Detail      = $_.Exception.Message
        }
    }
}

# ============================================================
# 11. DIRECTORY AUDIT TEST
# ============================================================

Invoke-GraphQuerySafe `
    -QueryName "DirectoryAudit" `
    -Operation {
        Get-MgAuditLogDirectoryAudit `
            -Top 10 `
            -ErrorAction Stop
    } |
    Format-List

# ============================================================
# 12. CONTROLLED FAILURE TEST
# ============================================================

Invoke-GraphQuerySafe `
    -QueryName "FailureTest" `
    -Operation {
        throw "Intentional test error"
    } |
    Format-List

# ============================================================
# 13. CLEANUP
# ============================================================

Disconnect-MgGraph
