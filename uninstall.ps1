# Deniz PC Monitör kaldırma
Get-ScheduledTask -TaskName 'Deniz PC Monitor (aktivite kaydi)' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Path -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like '*pc-monitor.ps1*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramData 'DenizPCMonitor') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Deniz PC Monitör kaldırıldı.' -ForegroundColor Green
