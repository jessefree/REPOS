param (
    [int]$threshold = 75,
    [int]$duration = 15
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
        Write-Host "Message: $message"
    } catch {
        $errorMessage = "Failed to send SMS to $toPhoneNumber. Error: $($_.Exception.Message)"
        Write-Host $errorMessage
        Write-Host "Error: $($_.Exception.Message)"
    }
}

# Set parameters
$counter = '\Processor(_Total)\% Processor Time'
$sampleInterval = 5      # Interval between samples in seconds
$samplesNeeded = [math]::Ceiling($duration / $sampleInterval)
$remoteComputer = "mds-ldc1-data1"

# Initialize variables
$aboveThresholdCount = 0
$lastSmsSentTime = [datetime]::MinValue

# Monitor loop
while ($true) {
    try {
        $data = Get-Counter -Counter $counter -SampleInterval $sampleInterval -MaxSamples 1 -ComputerName $remoteComputer
        $processorUtility = $data.CounterSamples.CookedValue

        Write-Output "Timestamp: $(Get-Date) - % Processor Time on ${remoteComputer}: $processorUtility"

        if ($processorUtility -ge $threshold) {
            $aboveThresholdCount++
            if ($aboveThresholdCount -ge $samplesNeeded) {
                $currentTime = Get-Date
                if (($currentTime - $lastSmsSentTime).TotalMinutes -ge 5) {
                    $message = "Processor Time on ${remoteComputer} has been at or above $threshold% for $duration seconds!"
                    Write-Warning $message
                    # Send SMS
                    try {
                        $recipients = Import-Csv -Path "\\mds-ldc1-data1\repos$\SPIRE_Monitoring\Components\smslist.txt"
                        foreach ($recipient in $recipients) {
                            $phoneNumber = $recipient.'# to sms'
                            Send-SMS -toPhoneNumber $phoneNumber -message $message
                            Write-Host "Sending SMS to: $phoneNumber"
                            Write-Host "SMS Message: $message"
                        }
                        $lastSmsSentTime = $currentTime # Update the last SMS sent time
                    } catch {
                        Write-Error "Failed to import CSV or send SMS: $_"
                    }
                }
                $aboveThresholdCount = 0 # Reset the counter after alerting
            }
        } else {
            $aboveThresholdCount = 0 # Reset the counter if usage drops below threshold
        }
    } catch {
        Write-Error "Error retrieving counter from ${remoteComputer}: $_"
    }

    Start-Sleep -Seconds $sampleInterval
}
    