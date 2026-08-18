$ScriptRoot = $PSScriptRoot
$ConfigFile = Join-Path $ScriptRoot "config.json"
$CredFile   = Join-Path $ScriptRoot "admincred.xml"

$LogPath = Join-Path $ScriptRoot "Logs"
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory | Out-Null
}

$LogFile = Join-Path $LogPath ("DistributionCheck_{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
$OutputPath = Join-Path $ScriptRoot "UsersMissingDistributionGroup.json"

$DistributionGroups = @(
    "GT-NY","GT-NJ","GT-PA","GT-AK","GT-Remote",
    "GW-NY","GW-NJ","GW-Remote",
    "TOP-NY","TOP-NJ","TOP-AK","TOP-Remote",
    "SA-NY","SA-NJ","SA-Remote",
    "JA-NY","JA-NJ","JA-Remote",
    "RL-NJ","RL-PA","RL-CA","RL-Remote"
)

function Write-Log {
    param($Message, $Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line
}

function Connect-Admin {
    param($AdminEmail)

    try {
        Connect-ExchangeOnline -UserPrincipalName $AdminEmail -ShowProgress $true -ErrorAction Stop
        Write-Log "Connected to Exchange as $AdminEmail" Green
    }
    catch {
        Write-Log "Exchange connection failed: $_" Red
        throw
    }
}

function Get-ActiveNonConsultantUsers {
    param($Credential)

    Write-Log "Getting filtered AD users..." Cyan

    $users = Get-ADUser `
        -Filter "Enabled -eq 'True'" `
        -Credential $Credential `
        -Properties DisplayName, SamAccountName, UserPrincipalName, Mail, Title, Department, DistinguishedName

    $filtered = $users | Where-Object {
        $_.Mail -and
        $_.Mail -match '@' -and
        $_.Title -notmatch "consultant" -and

        # Kill obvious system/service accounts
        $_.SamAccountName -notmatch '^(Administrator|Guest|krbtgt|IUSR|IWAM)' -and

        # Kill shared/resource style names
        $_.DisplayName -notmatch '(Admin|Test|Temp|Room|Conference|Invoice|Shipping|Receiving|Board|Committee|Domains|Fedex|UPS|System)' -and

        # Kill known non-user OUs (adjust if needed)
        $_.DistinguishedName -notmatch 'OU=Service|OU=Shared|OU=Resources|OU=Rooms|OU=Contacts'
    }

    Write-Log "Filtered users: $($filtered.Count)" Green
    return $filtered
}

function Get-DistributionGroupMembersMap {
    param($GroupNames)

    $map = @{}

    foreach ($group in $GroupNames) {
        try {
            Write-Log "Checking group: $group" Cyan

            $members = Get-DistributionGroupMember -Identity $group -ResultSize Unlimited

            $emails = $members | ForEach-Object {
                if ($_.PrimarySmtpAddress) {
                    $_.PrimarySmtpAddress.ToString().Trim().ToLower()
                }
                elseif ($_.WindowsEmailAddress) {
                    $_.WindowsEmailAddress.ToString().Trim().ToLower()
                }
            } | Where-Object { $_ }

            $map[$group] = @($emails)

            Write-Log "$group → $($emails.Count) members" Green
        }
        catch {
            Write-Log "Failed group: $group" Yellow
            $map[$group] = @()
        }
    }

    return $map
}

function Get-UsersNotInGroups {
    param($Users, $GroupMap)

    $missing = @()

    foreach ($user in $Users) {
        $email = $user.Mail.ToString().Trim().ToLower()
        $found = $false

        foreach ($group in $GroupMap.Keys) {
            if ($GroupMap[$group] -contains $email) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            Write-Log "Missing group: $($user.DisplayName) <$email>" Yellow

            $missing += [PSCustomObject]@{
                DisplayName = $user.DisplayName
                Email       = $email
                Department  = $user.Department
                Title       = $user.Title
            }
        }
    }

    return $missing
}

# =========================
# RUN
# =========================

try {
    Write-Log "Starting audit..." Cyan

    $config = Get-Content $ConfigFile | ConvertFrom-Json
    $adminEmail = $config.AdminEmail
    $cred = Import-Clixml $CredFile

    Connect-Admin -AdminEmail $adminEmail

    $users = Get-ActiveNonConsultantUsers -Credential $cred
    $groupMap = Get-DistributionGroupMembersMap -GroupNames $DistributionGroups
    $missingUsers = Get-UsersNotInGroups -Users $users -GroupMap $groupMap

    $missingUsers |
        Sort-Object Department, DisplayName |
        ConvertTo-Json -Depth 5 |
        Set-Content $OutputPath

    Write-Log "Done. Missing users: $($missingUsers.Count)" Yellow
    Write-Log "Saved to $OutputPath" Green
}
catch {
    Write-Log "Script failed: $_" Red
}