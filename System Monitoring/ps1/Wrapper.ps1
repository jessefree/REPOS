# Wrapper.ps1
param (
    [string]$scriptPath = "\\mds-ldc1-data1\repos$\System Monitoring\ps1\CPU Mon.ps1",
    [string]$logFile = "\\mds-ldc1-data1\repos$\System Monitoring\logs\CPU_Mon.log"
)

try {
    Start-Transcript -Path $logFile -Append
    Write-Host "Starting script: $scriptPath"
    & $scriptPath @PSBoundParameters
} catch {
    Write-Error "An error occurred: $_"
} finally {
    Write-Host "Script execution completed."
    Stop-Transcript
}
