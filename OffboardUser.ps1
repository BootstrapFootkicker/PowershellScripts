#Disable user in AD
#convert mailbox to shared in Exchange Online
#remove user from distribution groups
#if mailbox exceeds 50gb give them a exchange online license
#remind user to delete plm and as400 accounts
param(
    [switch]$csv
)

#utilize the Microsoft Graph PowerShell SDK to connect to Microsoft Graph and manage users and groups in Azure AD and Exchange Online. The script will prompt the user for their admin email to authenticate and will also allow for bulk processing of users from a CSV file. The script will disable user accounts in
function Connect-Admin {
    while ($true) {
        $adminEmail = Read-Host "Enter your admin email for authentication"
        try {
            Connect-ExchangeOnline -UserPrincipalName $adminEmail -ShowProgress $true -ErrorAction Stop
            Write-host "Successfully connected to Exchange as $adminEmail" Green
            return $adminEmail
        }
        catch {
            Write-host "Failed to connect to Exchange. Please check your email and try again." Red
        }
    }
}

function Connect-GraphAdmin {
    try {
        Connect-MgGraph -Scopes Application.Read.All, AppRoleAssignment.ReadWrite.All, Directory.Read.All, Group.ReadWrite.All, User.ReadWrite.All, Organization.Read.All -NoWelcome
        Write-Host "Connected to Microsoft Graph." -ForegroundColor Green
    }
    catch {
        Write-host "Failed to connect to Microsoft Graph: $_" Red
    }
}


function disableUserInAD {
    param(
        [switch]$csv,$users
    )

    if ($csv) {
       
        foreach ($user in $users) {
            $cred = Import-Clixml "C:\Users\ksealy\admincred.xml"
           $adUser = Get-ADUser -Identity $user.Username -Credential $cred -ErrorAction SilentlyContinue
            if ($adUser -ne $null) {
                Disable-ADAccount -Identity $adUser -Credential $cred
                Write-Host "Disabled user $($adUser.Name) in AD." -ForegroundColor Green
             
            }
            else {
                Write-Host "User with email $($user.Name) not found in AD." -ForegroundColor Red

            }
        }
        return
    }

# If not using CSV, prompt for user input
    Write-Host "Enter the username or full email of the user to disable in AD:" -ForegroundColor Cyan
    $lookup = Read-Host


     # Load credentials and user data for AD 
    $cred = Import-Clixml "C:\Users\ksealy\admincred.xml"
    $user = Get-ADUser -Identity $lookup -Credential $cred -ErrorAction SilentlyContinue
    
    if($user  -eq $null) {
        Write-host "User with email $lookup not found in AD." Red
        return
    }
    Disable-ADAccount -Identity $user -Credential $cred
    Write-host "Disabled user $lookup in AD." Green


}

function removeUserFromDistributionGroups {
    param(
        [string]$user
    )

    try {
        Write-Host "Checking distribution groups for $user..." -ForegroundColor Cyan
        $foundGroup = $false
        $groups = Get-DistributionGroup -ResultSize Unlimited

        foreach ($group in $groups) {
            if ($group.Name -eq "veeam") {
                continue
            }

            $members = Get-DistributionGroupMember -Identity $group.Identity -ResultSize Unlimited -ErrorAction SilentlyContinue

            if ($members.PrimarySmtpAddress -contains $user) {
                $foundGroup = $true
                Remove-DistributionGroupMember -Identity $group.Identity -Member $user -Confirm:$false
                Write-Host "Removed user $user from distribution group $($group.Name)." -ForegroundColor Green
            }
        }

        if (-not $foundGroup) {
            Write-Host "User $user is not in any removable distribution groups." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Failed to check/remove distribution groups for $user : $_" -ForegroundColor Red
    }
}

function convertToSharedMailbox {
    param(
        [string]$userPrincipalName
    )
    try {
        Set-Mailbox -Identity $userPrincipalName -Type Shared -ErrorAction Stop
       
    }
    catch {
        Write-Host "Failed to convert $userPrincipalName to a shared mailbox: $_" -ForegroundColor Red
    }
}
function offboardUser {
    param (
        [switch]$csv
    )

    $users = Import-Csv "C:\Users\ksealy\OneDrive - GOLDEN TOUCH IMPORTS\Desktop\Github\PowershellScripts\disableUsers.csv"

    # step 1 disable user in AD
    disableUserInAD -csv:$csv -users $users

    $cred = Import-Clixml "C:\Users\ksealy\admincred.xml"
    $exchangeSkuId = "19ec0d23-8335-4cbd-94ac-6050e30712fa"

    foreach ($user in $users) {

        $adUser = Get-ADUser -Identity $user.Username -Credential $cred -Properties UserPrincipalName,mail -ErrorAction SilentlyContinue

        if ($adUser -eq $null) {
            Write-Host "Could not find AD user for $($user.Username), skipping Exchange, distribution groups, and license steps." -ForegroundColor Red
            continue
        }

        $exchangeIdentity = if ($adUser.mail) { $adUser.mail } else { $adUser.UserPrincipalName }

        if (-not $exchangeIdentity) {
            Write-Host "Could not determine Exchange identity for $($user.Username), skipping Exchange, distribution groups, and license steps." -ForegroundColor Red
            continue
        }

        $graphUser = Get-MgUser -UserId $exchangeIdentity -Property Id,DisplayName,UserPrincipalName,AssignedLicenses -ErrorAction SilentlyContinue
        $assignedSkuIds = @()

        if ($graphUser) {
            $assignedSkuIds = @($graphUser.AssignedLicenses | Select-Object -ExpandProperty SkuId)
        }

        # step 2 convert mailbox to shared in Exchange Online
        convertToSharedMailbox -userPrincipalName $exchangeIdentity

        $mailboxStats = Get-EXOMailboxStatistics -Identity $exchangeIdentity -ErrorAction SilentlyContinue

        if ($mailboxStats) {
            $mailboxSizeGB = [math]::Round(($mailboxStats.TotalItemSize.Value.ToBytes() / 1GB), 2)

            if ($mailboxSizeGB -ge 50) {
                if (-not $graphUser) {
                    Write-Host "Mailbox for $exchangeIdentity is $mailboxSizeGB GB, but the user could not be found in Microsoft Graph to verify/assign Exchange Online license." -ForegroundColor Red
                }
                elseif ($assignedSkuIds -contains $exchangeSkuId) {
                    Write-Host "Mailbox for $exchangeIdentity is $mailboxSizeGB GB and already has Exchange Online assigned." -ForegroundColor Yellow
                }
                else {
                    try {
                        Set-MgUserLicense -UserId $graphUser.Id -AddLicenses @(@{SkuId = $exchangeSkuId}) -RemoveLicenses @() -ErrorAction Stop
                        Write-Host "Assigned Exchange Online license to $exchangeIdentity because mailbox is over 50 GB." -ForegroundColor Green
                        $assignedSkuIds += $exchangeSkuId
                    }
                    catch {
                        Write-Host "Mailbox for $exchangeIdentity is over 50 GB and needs an Exchange Online license. Please buy or reallocate one." -ForegroundColor Red
                    }
                }
            }
        }
        else {
            Write-Host "Could not get mailbox statistics for $exchangeIdentity." -ForegroundColor Red
        }

        # step 3 remove user from distribution groups
        removeUserFromDistributionGroups -user $exchangeIdentity

        # step 4 remove all licenses except Exchange Online if assigned
        if (-not $graphUser) {
            Write-Host "Could not find user $exchangeIdentity in Microsoft Graph, skipping license removal." -ForegroundColor Red
            continue
        }

        if (-not $assignedSkuIds -or $assignedSkuIds.Count -eq 0) {
            Write-Host "No licenses assigned to user $exchangeIdentity." -ForegroundColor Yellow
            continue
        }

        $licensesToRemove = $assignedSkuIds | Where-Object { $_ -ne $exchangeSkuId }

        if (-not $licensesToRemove -or $licensesToRemove.Count -eq 0) {
            Write-Host "No non-Exchange licenses to remove for $exchangeIdentity." -ForegroundColor Yellow
            continue
        }

        try {
            Set-MgUserLicense -UserId $graphUser.Id -RemoveLicenses $licensesToRemove -AddLicenses @{} -ErrorAction Stop
            Write-Host "Removed all non-Exchange licenses from user $exchangeIdentity." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to remove licenses from user $exchangeIdentity : $_" -ForegroundColor Red
        }
    }

    # step 5 remind user to delete plm and as400 accounts
    Write-Host "Please remember to delete the PLM and AS400 accounts for the offboarded users." -ForegroundColor Yellow
}
cls
$null = Connect-Admin
Connect-GraphAdmin

offboardUser -csv


