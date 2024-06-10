@echo off
powershell.exe -ExecutionPolicy Bypass -File "\\mds-ldc1-data1\repos$\System Monitoring\ps1\Wrapper.ps1" -logFile "\\mds-ldc1-data1\repos$\System Monitoring\logs\CPU_Mon.log"
