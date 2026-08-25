#==========================
# Where brains of script will live
#==========================
param(
    [switch]$WhatIf
)

$ScriptRoot = $PSScriptRoot #Where script file lives
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$CredFile   = Join-Path $PSScriptRoot "admincred.xml"
$CsvFile    = Join-Path $PSScriptRoot "NewHire.csv"



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
    param(
        $adminEmail
    )
    $attempts = 0
    while ($attempts -lt 5) {
        try {
            Connect-ExchangeOnline -UserPrincipalName $adminEmail -Device -ShowProgress $true -ErrorAction Stop
            Write-Log "Successfully connected to Exchange as $adminEmail" Green
            return $adminEmail
        }
        catch {
            $attempts++
            Write-Log "Failed to connect to Exchange (attempt $attempts/5): $($_.Exception.Message)" Red
            Start-Sleep -Seconds 2
        }
    }
    throw "Could not connect to Exchange after 5 attempts."
}

function Connect-GraphAdmin {
    try {
        Connect-MgGraph -Scopes Application.Read.All, AppRoleAssignment.ReadWrite.All, Directory.Read.All, Group.ReadWrite.All, User.ReadWrite.All, Organization.Read.All -NoWelcome -ErrorAction Stop
        Write-Log "Connected to Microsoft Graph." Green
    }
    catch {
        Write-Log "Failed to connect to Microsoft Graph: $_" Red
        exit 1 #exits script if connection fails
    }
}

# =========================
# Group selection (ask once)
# =========================
function Get-SelectedGroups 
{
    param(
        [string]$username
        )

    $GroupOptions = @{
        1  = "GT-NY"
        2  = "GT-NJ"
        3  = "GT-PA"
        4  = "GT-AK"
        5  = "GT-Remote"
        6  = "GW-NY"
        7  = "GW-NJ"
        8  = "GW-Remote"
        9  = "TOP-NY"
        10 = "TOP-NJ"
        11 = "TOP-AK"
        12 = "TOP-Remote"
        13 = "SA-NY"
        14 = "SA-NJ"
        15 = "SA-Remote"
        16 = "JA-NY"
        17 = "JA-NJ"
        18 = "JA-Remote"
        19 = "RL-NJ"
        20 = "RL-PA"
        21 = "RL-CA"
        22 = "RL-Remote"
    }

    Write-Host ""
    Write-Host "Choose a distribution group for ${username}:" -ForegroundColor Cyan

    foreach ($key in ($GroupOptions.Keys | Sort-Object)) {
        Write-Host "$key = $($GroupOptions[$key])"
    }

    do {
        $selection = Read-Host "Enter a number from 1 to 22"
    } until (
        $selection -match '^\d+$' -and
        $GroupOptions.ContainsKey([int]$selection)
    )

    return @($GroupOptions[[int]$selection])
}

# =========================
# Username collision resolver
# =========================
function Get-AvailableUsername {
    param(
        [string]$BaseUsername,
        [string]$AlternateUsername,
        [pscredential]$Credential
    )

    $candidate = $BaseUsername
    #$counter = 2

    while ($true) {
        $existingUser = Get-ADUser -Filter "SamAccountName -eq '$candidate'" -Credential $Credential -ErrorAction SilentlyContinue
        if (-not $existingUser) {
            return $candidate
        }

    Write-Host "Username $candidate already exists. Confirm user does not already exist." -ForegroundColor Yellow
    $response = Read-Host "Type YES to continue or EXIT to cancel"        
        
    #preventing duplicate accounts for existing user
    if ($response.ToLower() -eq "exit") {
        Write-Log "User creation cancelled by operator." Red
        throw "User creation cancelled."
    }
    elseif ($response.ToLower() -eq "yes") {
        $candidate = $AlternateUsername
       # $counter++  
    }
    else {
        Write-Host "Invalid response. Please type YES to continue or EXIT to cancel." -ForegroundColor Yellow
    }
      
    }
}

# =========================
# AD user creation
# =========================
function AddUsersToAD {
    param(
        [switch]$WhatIf
    )

    # Load credentials and user data for AD 
    $cred = Import-Clixml $CredFile
    $users = Import-Csv $CsvFile

    $createdUsers = @()

    foreach ($user in $users) {
     if ([string]::IsNullOrWhiteSpace($user.FirstName) -or
    [string]::IsNullOrWhiteSpace($user.LastName) -or
    [string]::IsNullOrWhiteSpace($user.Email) -or
    [string]::IsNullOrWhiteSpace($user.Manager) -or
    [string]::IsNullOrWhiteSpace($user.TemplateUser)) {

    Write-Log "Skipping blank or incomplete CSV row." Yellow
    continue
}

        # Remove non-ASCII characters from names to avoid AD issues      
       $firstName = ($user.FirstName -replace '[^\x00-\x7F]', '') -replace '\s+', ''
       $lastName  = ($user.LastName  -replace '[^\x00-\x7F]', '') -replace '\s+', ''   

        $displayName = "$firstName $lastName"
        $baseUsername = ($firstName[0] + $lastName).ToLower()
        $alternateUsername = ($firstName + $lastName).ToLower()
        $username    = Get-AvailableUsername -BaseUsername $baseUsername -AlternateUsername $alternateUsername -Credential $cred
        $email       = "$username@$($user.Email)"
        $jobTitle    = $user.JobTitle
        $department  = $user.Department
        $description = "Start Date: $($user.Description)"
        $distGroup = Get-SelectedGroups -username $username

        $managerIdentity = $user.Manager

while ($true) {
    try {
        $manager = Get-ADUser `
            -Identity $managerIdentity `
            -Credential $cred `
            -ErrorAction Stop

        Write-Log "Manager found: $($manager.Name)" Green
        break
    }
    catch {
        Write-Log "Manager '$managerIdentity' does not exist or could not be found." Yellow

        $managerIdentity = Read-Host "Enter the correct manager username"
    }
}
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
            distGroup = $distGroup
        }
    }

    return $createdUsers
}

# =========================
# Batched sync checks (check ALL users at once instead of one-by-one)
# =========================
function Wait-ForAzureSyncBatch {
    param(
        [array]$Emails
    )

    $pending = [System.Collections.Generic.List[string]]::new()
    $pending.AddRange([string[]]$Emails)

    $synced = @{}
    $attempts = 0
    $maxAttempts = 30   # 30 x 30s = 15 min ceiling

    Write-Log "Waiting for Azure sync for $($pending.Count) user(s): $($pending -join ', ')" Cyan

    while ($pending.Count -gt 0 -and $attempts -lt $maxAttempts) {
        $stillPending = [System.Collections.Generic.List[string]]::new()

        foreach ($email in $pending) {
            try {
                $null = Get-MgUser -UserId $email -ErrorAction Stop
                $synced[$email] = $true
                Write-Log "$email synced to Azure." Green
            }
            catch {
                $stillPending.Add($email)
            }
        }

        $pending = $stillPending

        if ($pending.Count -gt 0) {
            $attempts++
            Write-Log "$($pending.Count) user(s) still not synced to Azure (attempt $attempts/$maxAttempts): $($pending -join ', ')" Yellow
            Start-Sleep -Seconds 30
        }
    }

    foreach ($email in $pending) {
        Write-Log "$email never synced to Azure within timeout." Red
        $synced[$email] = $false
    }

    return $synced
}

function Wait-ForExchangeSyncBatch {
    param(
        [array]$Emails
    )

    $pending = [System.Collections.Generic.List[string]]::new()
    $pending.AddRange([string[]]$Emails)

    $synced = @{}
    $attempts = 0
    $maxAttempts = 80   # 80 x 15s = 20 min ceiling (was 30 = 7.5 min)

    Write-Log "Waiting for Exchange sync for $($pending.Count) user(s): $($pending -join ', ')" Cyan

    while ($pending.Count -gt 0 -and $attempts -lt $maxAttempts) {
        $stillPending = [System.Collections.Generic.List[string]]::new()

        foreach ($email in $pending) {
            try {
                Get-Recipient -Identity $email -ErrorAction Stop | Out-Null
                $synced[$email] = $true
                Write-Log "$email is now available in Exchange." Green
            }
            catch {
                $stillPending.Add($email)
            }
        }

        $pending = $stillPending

        if ($pending.Count -gt 0) {
            $attempts++
            Write-Log "$($pending.Count) user(s) still not in Exchange (attempt $attempts/$maxAttempts): $($pending -join ', ')" Yellow
            Start-Sleep -Seconds 15
        }
    }

    foreach ($email in $pending) {
        Write-Log "$email never became available in Exchange within timeout." Red
        $synced[$email] = $false
    }

    return $synced
}

# =========================
# License assignment
# =========================
function Assign-License {
    param(
        [string]$Email,
        [switch]$WhatIf
    )

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
            Add-DistributionGroupMember `
                -Identity $group `
                -Member $Email `
                -ErrorAction Stop |
                Out-Null

            Write-Log "Added $Email to distribution group $group" Green
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

function Initialize-Script {
    param(
        [string]$ScriptRoot
    )

    $missingFile = $false

    Write-Log "Initializing script..."

    if (-not (Test-Path $ConfigFile)) {
        try {
            $adminEmail = Read-Host "Enter your admin email for authentication"

            $config = @{
                AdminEmail = $adminEmail
            }

            $config | ConvertTo-Json | Set-Content $ConfigFile

            Write-Log "config.json has been created" Green
            $missingFile = $true
        }
        catch {
            Write-Log "config.json could not be created! $_" Red
        }
    }

    if (-not (Test-Path $CredFile)) {
        try {
            $cred = Get-Credential
            $cred | Export-Clixml $CredFile

            Write-Log "admincred.xml has been created" Green
            $missingFile = $true
        }
        catch {
            Write-Log "admincred.xml could not be created! $_" Red
        }
    }

    if (-not (Test-Path $CsvFile)) {
        try {
            "FirstName,LastName,Email,Description,Manager,JobTitle,Department,TemplateUser" | Set-Content $CsvFile

            Write-Log "NewHire.csv has been created" Green
            $missingFile = $true
        }
        catch {
            Write-Log "NewHire.csv could not be created! $_" Red
        }
    }

    if ($missingFile) {
        Write-Log "Script has initialized. Please fill out NewHire.csv, then rerun the script." Yellow
        exit
    }
}




$createdUsers = AddUsersToAD -WhatIf:$WhatIf

# Wait ONCE for the whole batch instead of per-user
$azureSyncResults = Wait-ForAzureSyncBatch -Emails ($createdUsers | ForEach-Object { $_.Email })
$exchangeSyncResults = Wait-ForExchangeSyncBatch -Emails ($createdUsers | ForEach-Object { $_.Email })

foreach ($createdUser in $createdUsers) {
    Write-Log "Processing post-creation tasks for $($createdUser.Email)" Cyan

    if ($azureSyncResults[$createdUser.Email]) {
        Assign-License -Email $createdUser.Email -WhatIf:$WhatIf
        Add-UserToVeeamGroup -Email $createdUser.Email -WhatIf:$WhatIf
        Add-UserToCatoProvisioning -Email $createdUser.Email -WhatIf:$WhatIf
    }
    else {
        Write-Log "Skipping license/Graph group tasks for $($createdUser.Email) — never synced to Azure." Red
    }

    if ($exchangeSyncResults[$createdUser.Email]) {
        Add-UserToDistributionGroups -Email $createdUser.Email -Groups $createdUser.distGroup -WhatIf:$WhatIf
    }
    else {
        Write-Log "Skipping distribution group assignment for $($createdUser.Email) — never became available in Exchange." Red
    }
}

Write-Log "Onboarding script complete. Log file: $LogFile" Green