param (
    [bool]$SendSMS = $true  # Set to $true to enable sending SMS notifications, default is to print to screen
)

# Load TwilioConfig.ps1 to set Twilio credentials
. "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\Components\TwilioConfig.ps1"

# Function to send an SMS using Twilio REST API
function Send-SMS {
    param (
        [string]$toPhoneNumber,
        [string]$message
    )

    $twilioAccountSid = $env:TWILIO_ACCOUNT_SID
    $twilioAuthToken = $env:TWILIO_AUTH_TOKEN
    $twilioPhoneNumber = $env:TWILIO_PHONE_NUMBER

    if (-not $twilioAccountSid -or -not $twilioAuthToken -or -not $twilioPhoneNumber) {
        Write-Host "Twilio credentials are not set. Cannot send SMS."
        return
    }

    $url = "https://api.twilio.com/2010-04-01/Accounts/$twilioAccountSid/Messages.json"

    $encodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${twilioAccountSid}:${twilioAuthToken}"))
    $headers = @{
        Authorization = "Basic $encodedCredentials"
    }

    $body = @{
        From = $twilioPhoneNumber
        To = $toPhoneNumber
        Body = $message
    }

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -ContentType "application/x-www-form-urlencoded"
        $statusMessage = "SMS sent to $toPhoneNumber - $($response.status)"
        Write-Host $statusMessage
        # Print to console the same info that is being sent in SMS
        Write-Host "Message: $message"
    } catch {
        $errorMessage = "Failed to send SMS to $toPhoneNumber. Error: $($_.Exception.Message)"
        Write-Host $errorMessage
        # Print to console the same info that is being sent in SMS
        Write-Host "Error: $($_.Exception.Message)"
    }
}

# Import the required scripts
. "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\Components\NormalizeRosebudSync.ps1"
. "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\Components\NormalizeCRServer.ps1"
. "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\Components\NormalizeGJServer.ps1"

# Get the list of server names from the file
$serversFilePath = "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\mdswatcher_contents_monitor\MDS_Watcher_Servers.txt"
$servers = Get-Content -Path $serversFilePath

# Get normalized data for each server type
$normalizedRosebudSyncData = NormalizeRosebudSync -remoteMachineListPath $serversFilePath -mdsWatcherFolderPath "MDSRuntime"
$normalizedCRServerData = NormalizeCRServer -remoteMachineListPath $serversFilePath -mdsWatcherFolderPath "MDSRuntime"
$normalizedGJServerData = NormalizeGJServer -remoteMachineListPath $serversFilePath -mdsWatcherFolderPath "MDSRuntime"

# Function to fetch all relevant processes from a server
function Get-RelevantProcesses {
    param (
        [string]$server,
        [array]$commandNames
    )

    try {
        $processes = Get-CimInstance -ComputerName $server Win32_Process -ErrorAction Stop
        $filteredProcesses = $processes | Where-Object { 
            $commandLine = $_.CommandLine
            $commandNames | Where-Object { $commandLine -like "*$_*" }
        }
        return $filteredProcesses
    } catch {
        Write-Host "Failed to fetch processes from $server. Error: $($_.Exception.Message)"
        Read-Host "Press Enter to continue..."
        return @()
    }
}

# Aggregate all command names for fetching processes
$allCommandNames = @("RosebudSync", "CRServer", "GJServer")

# Fetch all relevant processes from each server in a single call
$allServerProcesses = @{}
foreach ($server in $servers) {
    $allServerProcesses[$server] = Get-RelevantProcesses -server $server -commandNames $allCommandNames
}

# Filter out lines containing "TableID" from RosebudSync data
$filteredRosebudSyncData = $normalizedRosebudSyncData | Where-Object { $_ -notmatch 'TableID' }

# Define the log file path
$logFilePath = "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\mdswatcher_contents_monitor\log\non_running_processes.bat"

# Function to display command status, log non-running processes, and start them
function Display-CommandStatus-Log-And-Start {
    param (
        $normalizedData,
        $commandName,
        $allServerProcesses,
        $logFilePath
    )

    # Clear or initialize log file for fresh write
    "" | Set-Content -Path $logFilePath

    $statusReport = @{}
    $notRunningLines = @{}

    foreach ($line in $normalizedData) {
        # Remove all spaces for comparison
        $lineWithoutSpaces = $line -replace '\s', ''

        if (-not $statusReport.ContainsKey($lineWithoutSpaces)) {
            $statusReport[$lineWithoutSpaces] = @{
                "IsRunning" = $false
                "RunningServers" = @()
                "OriginalLine" = $line # Keep the original line for reference
            }
        }

        # Check if the line contains "TableID"
        if ($lineWithoutSpaces -notmatch 'TableID') {
            foreach ($server in $allServerProcesses.Keys) {
                $matched = $false
                foreach ($process in $allServerProcesses[$server]) {
                    $processCommandLine = $process.CommandLine
                    $processCommandLineWithoutSpaces = $processCommandLine -replace '\s', ''
                    if ($processCommandLineWithoutSpaces -eq $lineWithoutSpaces -or $processCommandLine -like "*$line*") {
                        $statusReport[$lineWithoutSpaces]["IsRunning"] = $true
                        $statusReport[$lineWithoutSpaces]["RunningServers"] += $server
                        $matched = $true
                        break
                    }
                }
                if ($matched) { break }
            }

            if (-not $statusReport[$lineWithoutSpaces]["IsRunning"]) {
                # Check if this server and process combination has already been added
                $alreadyReported = $notRunningLines.ContainsKey($lineWithoutSpaces)

                if (-not $alreadyReported) {
                    $notRunningLines[$lineWithoutSpaces] = $statusReport[$lineWithoutSpaces]["OriginalLine"]
                }
            }
        }
    }

    if ($notRunningLines.Count -gt 0) {
        foreach ($lineWithoutSpaces in $notRunningLines.Keys) {
            $originalLine = $notRunningLines[$lineWithoutSpaces]
            # Format and log the line in the new specified format
            $formattedLine = 'start "app" ' + $originalLine
            Add-Content -Path $logFilePath -Value $formattedLine
        }

        # Start the non-running processes by invoking the log file asynchronously
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$logFilePath`""

        # Allow some time for processes to start
        Start-Sleep -Seconds 10

        # Re-fetch all relevant processes from each server after starting them
        $allServerProcesses = @{}
        foreach ($server in $servers) {
            $allServerProcesses[$server] = Get-RelevantProcesses -server $server -commandNames $allCommandNames
        }

        # Re-check the status and send SMS notifications if still not running
        $stillNotRunningLines = @{}
        foreach ($line in $normalizedData) {
            $lineWithoutSpaces = $line -replace '\s', ''
            if (-not $statusReport[$lineWithoutSpaces]["IsRunning"]) {
                foreach ($server in $allServerProcesses.Keys) {
                    $matched = $false
                    foreach ($process in $allServerProcesses[$server]) {
                        $processCommandLine = $process.CommandLine
                        $processCommandLineWithoutSpaces = $processCommandLine -replace '\s', ''
                        if ($processCommandLineWithoutSpaces -eq $lineWithoutSpaces -or $processCommandLine -like "*$line*") {
                            $statusReport[$lineWithoutSpaces]["IsRunning"] = $true
                            $statusReport[$lineWithoutSpaces]["RunningServers"] += $server
                            $matched = $true
                            break
                        }
                    }
                    if ($matched) { break }
                }
                if (-not $statusReport[$lineWithoutSpaces]["IsRunning"]) {
                    $alreadyReported = $stillNotRunningLines.ContainsKey($lineWithoutSpaces)
                    if (-not $alreadyReported) {
                        $stillNotRunningLines[$lineWithoutSpaces] = $statusReport[$lineWithoutSpaces]["OriginalLine"]
                    }
                }
            }
        }

        if ($stillNotRunningLines.Count -gt 0) {
            if ($SendSMS) {
                # Read phone numbers from smslist.txt
                $smsListPath = "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\Components\smslist.txt"
                $recipients = Import-Csv -Path $smsListPath

                foreach ($lineWithoutSpaces in $stillNotRunningLines.Keys) {
                    $originalLine = $stillNotRunningLines[$lineWithoutSpaces]
                    $serverNamePattern = '\\\\[^\\]+\\([^\\$]+)\$'
                    $serverName = if ($originalLine -match $serverNamePattern) { $matches[1] } else { "Unknown" }
                    $message = "$commandName for $serverName not running."
                    foreach ($recipient in $recipients) {
                        Send-SMS -toPhoneNumber $recipient.'# to sms' -message $message
                        Write-Host "Sending SMS to: $recipient.'# to sms'"
                        Write-Host "SMS Message: $message"
                    }
                }
            } else {
                foreach ($lineWithoutSpaces in $stillNotRunningLines.Keys) {
                    $originalLine = $stillNotRunningLines[$lineWithoutSpaces]
                    $serverNamePattern = '\\\\[^\\]+\\([^\\$]+)\$'
                    $serverName = if ($originalLine -match $serverNamePattern) { $matches[1] } else { "Unknown" }
                    $message = "$commandName for $serverName not running."
                    Write-Host "SMS not sent. $message"
                }
            }
        } else {
            Write-Host "All $commandName commands are now running on at least one server."
        }
    } else {
        Write-Host "All $commandName commands are running on at least one server."
    }
}

# Display the status for each server type, log non-running processes, start them, and send SMS notifications if still not running
Write-Host "CRServer Commands Status:"
Display-CommandStatus-Log-And-Start $normalizedCRServerData "CRServer" $allServerProcesses $logFilePath
Write-Host "GJServer Commands Status:"
Display-CommandStatus-Log-And-Start $normalizedGJServerData "GJServer" $allServerProcesses $logFilePath

# Display the status for RosebudSync after filtering, log non-running processes, start them, and send SMS notifications if still not running
Write-Host "RosebudSync Commands Status (excluding lines with 'TableID'):"
Display-CommandStatus-Log-And-Start $filteredRosebudSyncData "RosebudSync" $allServerProcesses $logFilePath
