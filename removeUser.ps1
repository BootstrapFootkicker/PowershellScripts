$ScriptRoot = $PSScriptRoot
$CredFile   = Join-Path $ScriptRoot "admincred.xml"

Import-Module ActiveDirectory

$cred = Import-Clixml $CredFile

$usersToDelete = @(
    "asack",
    "mAguirre",
    "iBryant"
)

foreach ($username in $usersToDelete) {
    try {
        $adUser = Get-ADUser -Identity $username -Credential $cred -ErrorAction Stop

        Write-Host "Deleting user: $($adUser.SamAccountName)" -ForegroundColor Yellow

        Remove-ADUser -Identity $adUser.DistinguishedName -Credential $cred -Confirm:$false

        Write-Host "Deleted: $username" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to delete/find user: $username - $_" -ForegroundColor Red
    }
}