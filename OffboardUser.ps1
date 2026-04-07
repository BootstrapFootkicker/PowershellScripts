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
        $groups = Get-DistributionGroup -ResultSize Unlimited

        foreach ($group in $groups) {
            if ($group.Name -eq "veeam") {
                continue
            }

            $members = Get-DistributionGroupMember -Identity $group.Identity -ResultSize Unlimited -ErrorAction SilentlyContinue

            if ($members.PrimarySmtpAddress -contains $user) {
                Remove-DistributionGroupMember -Identity $group.Identity -Member $user -Confirm:$false
                Write-Host "Removed user $user from distribution group $($group.Name)." -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Host "Failed to remove user $user from distribution groups: $_" -ForegroundColor Red
    }
}

function convertToSharedMailbox {
    param(
        [string]$userPrincipalName
    )
    try {
        Set-Mailbox -Identity $userPrincipalName -Type Shared
        Write-Host "Converted $userPrincipalName to a shared mailbox." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to convert $userPrincipalName to a shared mailbox: $_" -ForegroundColor Red
    }
}
 function offboardUser {
        param (
            [switch]$csv)
             $users = Import-Csv "C:\Users\ksealy\OneDrive - GOLDEN TOUCH IMPORTS\Desktop\Github\PowershellScripts\disableUsers.csv"
            #step 1 disable user in AD
        disableUserInAD -csv:$csv -users $users
        #step 2 convert mailbox to shared in Exchange Online
   foreach ($user in $users) {
    convertToSharedMailbox -userPrincipalName $user.Username

    $mailboxStats = Get-EXOMailboxStatistics -Identity $user.Username
    $mailboxSizeGB = [math]::Round(($mailboxStats.TotalItemSize.Value.ToBytes() / 1GB), 2)

    if ($mailboxSizeGB -ge 50) {
        try {
            Write-Host "Mailbox for $($user.Username) is $mailboxSizeGB GB. Assign Exchange Online license here." -ForegroundColor Yellow
        }
        catch {
            Write-Host "You are out of Exchange Online licenses. Please purchase or reallocate more." -ForegroundColor Red
        }
    }
}
            #step 3 remove user from distribution groups
            foreach ($user in $users) {
                removeUserFromDistributionGroups -user $user.Username
            }
            #step 4 remind user to delete plm and as400 accounts
            Write-Host "Please remember to delete the PLM and AS400 accounts for the offboarded users." -ForegroundColor Yellow

    }
cls
$null = Connect-Admin
Connect-GraphAdmin

offboardUser -csv



