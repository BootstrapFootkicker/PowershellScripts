# Force PowerShell 7
if ($PSVersionTable.PSEdition -ne "Core") {
    Write-Host "⚠️ This script requires PowerShell 7+. Please run it in PowerShell 7 (pwsh)." -ForegroundColor Yellow
    exit
}

# Function to authenticate admin account
function Connect-Admin {
    while ($true) {
        $adminEmail = Read-Host "Enter your admin email for authentication"
        try {
            Connect-ExchangeOnline -UserPrincipalName $adminEmail -ShowProgress $true -ErrorAction Stop
            Write-Host "✅ Successfully connected as $adminEmail" -ForegroundColor Green
            return $adminEmail  # Return the valid email
        } catch {
            Write-Host "❌ Failed to connect. Please check your email and try again." -ForegroundColor Red
        }
    }
}

# Function to get a valid user email
function Get-ValidUserEmail {
    while ($true) {
        $userEmail = Read-Host "Enter the user's email to remove from groups"
        if ($userEmail -match "^[\w\.-]+@[\w\.-]+\.\w+$") {  # Basic email validation
            return $userEmail
        } else {
            Write-Host "❌ Invalid email format. Please enter a valid email." -ForegroundColor Red
        }
    }
}

# Authenticate admin
$adminEmail = Connect-Admin

# Get user email
$userEmail = Get-ValidUserEmail

# Start searching for groups
Write-Host "`n🔍 Searching for groups... Please wait."

# Retrieve all distribution groups where the user is a member
$userGroups = Get-DistributionGroup -ResultSize Unlimited | Where-Object {
    (Get-DistributionGroupMember -Identity $_.PrimarySmtpAddress -ResultSize Unlimited | Where-Object { $_.PrimarySmtpAddress -eq $userEmail })
}

# Search complete
Write-Host "`r✅ Search complete!`n"

# Check if the user is in any groups
if (-not $userGroups) {
    Write-Host "⚠️ No groups found for $userEmail." -ForegroundColor Yellow
} else {
    Write-Host "🔍 User is a member of the following groups:"
    $userGroups | ForEach-Object { Write-Host $_.PrimarySmtpAddress }

    # Filter groups ending with @gtimports.net
    $filteredGroups = $userGroups | Where-Object { $_.PrimarySmtpAddress -like "*@gtimports.net" }

    if (-not $filteredGroups) {
        Write-Host "⚠️ No groups matching '@gtimports.net' found." -ForegroundColor Yellow
    } else {
        Write-Host "🚀 Removing $userEmail from the following groups:"
        foreach ($group in $filteredGroups) {
            try {
                Remove-DistributionGroupMember -Identity $group.PrimarySmtpAddress -Member $userEmail -Confirm:$false
                Write-Host "✅ Removed from: $($group.PrimarySmtpAddress)" -ForegroundColor Green
            } catch {
                Write-Host "❌ Error removing from: $($group.PrimarySmtpAddress) - $_" -ForegroundColor Red
            }
        }
    }
}

# Disconnect from Exchange Online
Disconnect-ExchangeOnline -Confirm:$false
Write-Host "🔌 Disconnected from Exchange Online." -ForegroundColor Cyan
