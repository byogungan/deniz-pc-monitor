# Deniz PC Monitör kurulumu — açılışta başlayan görünür görev oluşturur.
# Kullanım (yönetici PowerShell):
#   $env:PCM_TOKEN='<token>'; irm https://raw.githubusercontent.com/<REPO>/main/install.ps1 | iex
param(
  [string]$Token = $env:PCM_TOKEN,
  [string]$ServerUrl = $(if ($env:PCM_SERVER) { $env:PCM_SERVER } else { 'https://crm.denizbelge.com' }),
  [string]$Repo = 'https://raw.githubusercontent.com/byogungan/deniz-pc-monitor/main'
)
if (-not $Token) { Write-Error 'PCM_TOKEN gerekli.'; exit 1 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Dir = Join-Path $env:ProgramData 'DenizPCMonitor'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# Ajan scriptini indir
Invoke-WebRequest -Uri "$Repo/pc-monitor.ps1" -OutFile (Join-Path $Dir 'pc-monitor.ps1') -UseBasicParsing

# Ayarları yaz
@{ serverUrl = $ServerUrl; token = $Token } | ConvertTo-Json | Set-Content (Join-Path $Dir 'config.json') -Encoding UTF8

# Açılışta çalışan görev (görünür adla — gizli değil)
$agent = Join-Path $Dir 'pc-monitor.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -WindowStyle Minimized -File `"$agent`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartInterval (New-TimeSpan -Minutes 5) -RestartCount 3
Register-ScheduledTask -TaskName 'Deniz PC Monitor (aktivite kaydi)' -Action $action -Trigger $trigger -Settings $settings -Description 'Sirket bilgisayari aktivite kaydi - personel bilgisi dahilinde.' -Force | Out-Null

# Hemen başlat
Start-ScheduledTask -TaskName 'Deniz PC Monitor (aktivite kaydi)'
Write-Host 'Deniz PC Monitör kuruldu ve başlatıldı.' -ForegroundColor Green
