param(
    [switch]$WhatIf
)

# =========================
# Logging
# =========================
$LogPath = "C:\Users\ksealy\OneDrive - GOLDEN TOUCH IMPORTS\Desktop\Scripts\Logs"
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory | Out-Null
}

$LogFile = Join-Path $LogPath ("NewUser_{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))

function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"

    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line
}

# =========================
# Connections
# =========================
function Connect-Admin {
    while ($true) {
        $adminEmail = Read-Host "Enter your admin email for authentication"
        try {
            Connect-ExchangeOnline -UserPrincipalName $adminEmail -ShowProgress $true -ErrorAction Stop
            Write-Log "Successfully connected to Exchange as $adminEmail" Green
            return $adminEmail
        }
        catch {
            Write-Log "Failed to connect to Exchange. Please check your email and try again." Red
        }
    }
}

function Connect-GraphAdmin {
    try {
        Connect-MgGraph -Scopes Application.Read.All, AppRoleAssignment.ReadWrite.All, Directory.Read.All, Group.ReadWrite.All, User.ReadWrite.All, Organization.Read.All -NoWelcome
        Write-Log "Connected to Microsoft Graph." Green
    }
    catch {
        Write-Log "Failed to connect to Microsoft Graph: $_" Red
    }
}

# =========================
# Group selection (ask once)
# =========================
function Get-SelectedGroups {
    $GroupOptions = @{
        1 = "GT-NY"
        2 = "GW-NY"
        3 = "JA-NY"
    }

    Write-Host ""
    Write-Host "Choose a distribution group for this run:" -ForegroundColor Cyan
    Write-Host "1 = GT-NY"
    Write-Host "2 = GW-NY"
    Write-Host "3 = JA-NY"

    do {
        $selection = Read-Host "Enter 1, 2, or 3"
    } until ($selection -match '^[1-3]$')

    return @($GroupOptions[[int]$selection])
}

# =========================
# Username collision resolver
# =========================
function Get-AvailableUsername {
    param(
        [string]$BaseUsername,
        [pscredential]$Credential
    )

    $candidate = $BaseUsername
    $counter = 2

    while ($true) {
        $existingUser = Get-ADUser -Filter "SamAccountName -eq '$candidate'" -Credential $Credential -ErrorAction SilentlyContinue
        if (-not $existingUser) {
            return $candidate
        }

        $candidate = "$BaseUsername$counter"
        $counter++
    }
}

# =========================
# AD user creation
# =========================
function AddUsersToAD {
    param(
        [switch]$WhatIf
    )

    $cred = Import-Clixml "C:\Users\ksealy\admincred.xml"
    $users = Import-Csv "C:\Users\ksealy\OneDrive - GOLDEN TOUCH IMPORTS\Desktop\Scripts\NewHire.csv"

    $createdUsers = @()

    foreach ($user in $users) {

        $firstName   = $user.FirstName
        $lastName    = $user.LastName
        $displayName = "$firstName $lastName"
        $baseUsername = ($user.FirstName[0] + $user.LastName).ToLower()
        $username    = Get-AvailableUsername -BaseUsername $baseUsername -Credential $cred
        $email       = "$username@$($user.Email)"
        $jobTitle    = $user.JobTitle
        $department  = $user.Department
        $description = "Start Date: $($user.Description)"

        $manager = Get-ADUser -Identity $user.Manager -Credential $cred

        $templateUser = Get-ADUser -Identity $user.TemplateUser `
            -Credential $cred `
            -Properties MemberOf, DistinguishedName

        $userPath = $templateUser.DistinguishedName -replace '^CN=[^,]+,', ''

        if ($username -ne $baseUsername) {
            Write-Log "Username $baseUsername already existed. Using $username instead." Yellow
        }

        Write-Log "Creating user $username in $userPath" Cyan

        try {
            if ($WhatIf) {
                Write-Log "[WhatIf] Would create AD user $username" Yellow
            }
            else {
                New-ADUser `
                    -GivenName $firstName `
                    -Surname $lastName `
                    -Name $displayName `
                    -DisplayName $displayName `
                    -SamAccountName $username `
                    -UserPrincipalName $email `
                    -EmailAddress $email `
                    -Title $jobTitle `
                    -Department $department `
                    -Description $description `
                    -Manager $manager.DistinguishedName `
                    -AccountPassword (ConvertTo-SecureString "Golden2026!" -AsPlainText -Force) `
                    -ChangePasswordAtLogon $true `
                    -Enabled $true `
                    -Path $userPath `
                    -Credential $cred

                Write-Log "User $username created successfully." Green
            }
        }
        catch {
            Write-Log "Failed to create user $username : $_" Red
            continue
        }

        foreach ($group in $templateUser.MemberOf) {
            if ($group -notmatch "Domain Admins|Enterprise Admins|Schema Admins") {
                try {
                    if ($WhatIf) {
                        Write-Log "[WhatIf] Would add $username to template group $group" Yellow
                    }
                    else {
                        Add-ADGroupMember `
                            -Identity $group `
                            -Members $username `
                            -Credential $cred
                    }
                }
                catch {
                    Write-Log "Failed adding $username to $group" Yellow
                }
            }
        }

        Write-Log "Permissions copied from template user." Green
        Write-Log "----------------------------------------" DarkGray

        $createdUsers += [PSCustomObject]@{
            Username = $username
            Email    = $email
        }
    }

    return $createdUsers
}

# =========================
# License assignment
# =========================
function Assign-License {
    param(
        [string]$Email,
        [switch]$WhatIf
    )

    Write-Log "Waiting for Azure sync for $Email..." Cyan

    $userSynced = $false
    $attempts = 0
    $maxAttempts = 60

    while (-not $userSynced -and $attempts -lt $maxAttempts) {
        try {
            $null = Get-MgUser -UserId $Email -ErrorAction Stop
            $userSynced = $true
            Write-Log "User synced to Azure." Green
        }
        catch {
            Write-Log "User not synced yet... waiting 30 seconds." Yellow
            Start-Sleep -Seconds 30
            $attempts++
        }
    }

    if (-not $userSynced) {
        Write-Log "User never synced. Aborting license assignment." Red
        return
    }

    try {
        if ($WhatIf) {
            Write-Log "[WhatIf] Would set usage location and assign E3 to $Email" Yellow
        }
        else {
            Update-MgUser -UserId $Email -UsageLocation "US" | Out-Null

            $e3Sku = Get-MgSubscribedSku -All | Where-Object { $_.SkuPartNumber -eq "ENTERPRISEPACK" }

            if (-not $e3Sku) {
                Write-Log "Could not find ENTERPRISEPACK in tenant SKUs." Red
                return
            }

            Set-MgUserLicense `
                -UserId $Email `
                -AddLicenses @(@{SkuId = $e3Sku.SkuId}) `
                -RemoveLicenses @() | Out-Null

            Write-Log "E3 license assigned to $Email" Green
        }
    }
    catch {
        Write-Log "Failed assigning license to $Email : $_" Red
    }
}

# =========================
# Distribution groups
# =========================
function Add-UserToDistributionGroups {
    param(
        [string]$Email,
        [array]$Groups,
        [switch]$WhatIf
    )

    foreach ($group in $Groups) {
        try {
            if ($WhatIf) {
                Write-Log "[WhatIf] Would add $Email to distribution group $group" Yellow
            }
            else {
                Add-DistributionGroupMember `
                    -Identity $group `
                    -Member $Email `
                    -ErrorAction Stop | Out-Null

                Write-Log "Added $Email to distribution group $group" Green
            }
        }
        catch {
            Write-Log "Failed to add $Email to distribution group $group : $_" Yellow
        }
    }
}

# =========================
# Veeam group
# =========================
function Add-UserToVeeamGroup {
    param(
        [string]$Email,
        [switch]$WhatIf
    )

    try {
        $veeamGroup = Get-MgGroup -Filter "displayName eq 'VeeamBBlazeEmail'" -ErrorAction Stop

        if (-not $veeamGroup) {
            Write-Log "Could not find VeeamBBlazeEmail in Microsoft 365." Yellow
            return
        }

        $cloudUser = Get-MgUser -UserId $Email -ErrorAction Stop

        if ($WhatIf) {
            Write-Log "[WhatIf] Would add $Email to VeeamBBlazeEmail" Yellow
        }
        else {
            New-MgGroupMemberByRef `
                -GroupId $veeamGroup.Id `
                -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($cloudUser.Id)" `
                | Out-Null

            Write-Log "Added $Email to VeeamBBlazeEmail" Green
        }
    }
    catch {
        Write-Log "Failed to add $Email to VeeamBBlazeEmail : $_" Yellow
    }
}

function Add-UserToCatoProvisioning {
    param(
        [string]$Email,
        [switch]$WhatIf
    )

    try {
        $catoProv = Get-MgServicePrincipal -Filter "displayName eq 'Cato Networks Provisioning'" -ErrorAction Stop

        if (-not $catoProv) {
            Write-Log "Could not find Cato Networks Provisioning enterprise app." Yellow
            return
        }

        $cloudUser = Get-MgUser -UserId $Email -ErrorAction Stop

        $appRoleId = "0b061251-fcae-4fb4-ba47-73c82f6fd290"

        if ($WhatIf) {
            Write-Log "[WhatIf] Would assign $Email to Cato Networks Provisioning" Yellow
        }
        else {
            New-MgServicePrincipalAppRoleAssignedTo `
                -ServicePrincipalId $catoProv.Id `
                -PrincipalId $cloudUser.Id `
                -ResourceId $catoProv.Id `
                -AppRoleId $appRoleId | Out-Null

            Write-Log "Added $Email to Cato Networks Provisioning" Green
        }
    }
    catch {
        Write-Log "Failed to add $Email to Cato Networks Provisioning : $_" Yellow
    }
}

# =========================
# Main
# =========================
clear
Write-Log "Starting onboarding script. WhatIf mode = $WhatIf" Cyan

$null = Connect-Admin
Connect-GraphAdmin

$selectedGroups = Get-SelectedGroups
Write-Log "Selected distribution group(s): $($selectedGroups -join ', ')" Cyan

$createdUsers = AddUsersToAD -WhatIf:$WhatIf

foreach ($createdUser in $createdUsers) {
    Assign-License -Email $createdUser.Email -WhatIf:$WhatIf
    Add-UserToDistributionGroups -Email $createdUser.Email -Groups $selectedGroups -WhatIf:$WhatIf
    Add-UserToVeeamGroup -Email $createdUser.Email -WhatIf:$WhatIf
    Add-UserToCatoProvisioning -Email $createdUser.Email -WhatIf:$WhatIf
}
Write-Log "Onboarding script complete. Log file: $LogFile" Green
