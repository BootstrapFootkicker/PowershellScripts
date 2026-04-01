#Disable user in AD
#convert mailbox to shared in Exchange Online
#remove user from distribution groups
#if mailbox exceeds 50gb give them a exchange online license
#remind user to delete plm and as400 accounts
param(
    [switch]$csv
)
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
        [switch]$csv
    )
 $users = Import-Csv "C:\Users\ksealy\OneDrive - GOLDEN TOUCH IMPORTS\Desktop\Github\PowershellScripts\disableUsers.csv"
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


    Write-Host "Enter the username or full email of the user to disable in AD:" -ForegroundColor Cyan
    $lookup = Read-Host


     # Load credentials and user data for AD 
    $cred = Import-Clixml "C:\Users\ksealy\admincred.xml"
    $user = Get-ADUser -Identity $lookup -Credential $cred   
    
    if($user  -eq $null) {
        Write-host "User with email $lookup not found in AD." Red
        return
    }
    Disable-ADAccount -Identity $user -Credential $cred
    Write-host "Disabled user $lookup in AD." Green


}
cls
$null = Connect-Admin
Connect-GraphAdmin

disableUserInAD -csv:$csv
