function createInactiveUserReport {
    $cred = Import-Clixml "C:\Users\ksealy\admincred.xml"
    $users = Import-Csv "C:\Users\ksealy\OneDrive - GOLDEN TOUCH IMPORTS\Desktop\Github\PowershellScripts\box_users.csv"

    $inactiveUsers = @()
    $notFoundUsers = @()

    foreach ($user in $users) {
        $email = $user.email

        if ([string]::IsNullOrWhiteSpace($email)) {
            continue
        }

        try {
            $adUser = Get-ADUser `
                -Filter "mail -eq '$email' -or UserPrincipalName -eq '$email'" `
                -Credential $cred `
                -Properties mail, Enabled, SamAccountName, UserPrincipalName, DisplayName

            if (-not $adUser) {
                $notFoundUsers += [PSCustomObject]@{
                    Email = $email
                }
                continue
            }

            if (-not $adUser.Enabled) {
                $inactiveUsers += [PSCustomObject]@{
                    DisplayName       = $adUser.DisplayName
                    Email             = $adUser.mail
                    SamAccountName    = $adUser.SamAccountName
                    UserPrincipalName = $adUser.UserPrincipalName
                    Enabled           = $adUser.Enabled
                }
            }
        }
        catch {
            Write-Host "Error checking $email : $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    return @{
        Inactive = $inactiveUsers
        NotFound = $notFoundUsers
    }
}

$result = createInactiveUserReport

Write-Host "`n================ INACTIVE USERS ================" -ForegroundColor Cyan
$result.Inactive | Format-Table DisplayName, Email, SamAccountName, UserPrincipalName, Enabled -AutoSize

Write-Host "`n================ NOT FOUND IN AD ================" -ForegroundColor Yellow
$result.NotFound | Format-Table Email -AutoSize