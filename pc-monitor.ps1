# ============================================================
#  Deniz PC Monitör — şeffaf aktivite kaydı ajanı
#  Açılma/kapanma, açılan uygulamalar ve uygulama kullanım
#  sürelerini toplayıp CRM'e (crm.denizbelge.com) gönderir.
#  ÖNEMLİ: Bu araç GİZLİ DEĞİLDİR. Görev çubuğunda ikon gösterir
#  ve yalnızca personelin bilgisi dahilinde, şirket cihazlarında
#  kullanılmalıdır.
# ============================================================

param(
  [string]$ServerUrl = $env:PCM_SERVER,
  [string]$Token     = $env:PCM_TOKEN,
  [int]$SampleSeconds = 5,     # kaç saniyede bir aktif pencereye bakılır
  [int]$SendSeconds   = 600,   # kaç saniyede bir CRM'e gönderilir (10 dk)
  [int]$IdleSeconds   = 60     # bu süre giriş yoksa "boşta" sayılır, süre eklenmez
)

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DataDir = Join-Path $env:ProgramData 'DenizPCMonitor'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$ConfigPath = Join-Path $DataDir 'config.json'
$DevicePath = Join-Path $DataDir 'device.json'

# --- Ayarları yükle/kaydet ---
if (-not $ServerUrl -or -not $Token) {
  if (Test-Path $ConfigPath) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $ServerUrl) { $ServerUrl = $cfg.serverUrl }
    if (-not $Token)     { $Token     = $cfg.token }
  }
}
if (-not $ServerUrl) { $ServerUrl = 'https://crm.denizbelge.com' }
if (-not $Token) { Write-Error 'Token gerekli. PCM_TOKEN ortam değişkeni ya da -Token parametresi verin.'; exit 1 }
@{ serverUrl = $ServerUrl; token = $Token } | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8

# --- Cihaz kimliği (bir kez üretilir) ---
if (Test-Path $DevicePath) {
  $dev = Get-Content $DevicePath -Raw | ConvertFrom-Json
  $DeviceId = $dev.deviceId
} else {
  $DeviceId = "$env:COMPUTERNAME-$([guid]::NewGuid().ToString('N').Substring(0,8))"
  @{ deviceId = $DeviceId } | ConvertTo-Json | Set-Content $DevicePath -Encoding UTF8
}
$DeviceName = $env:COMPUTERNAME

$IngestUrl = "$ServerUrl/api/v1/pc-monitor/ingest"

# --- Win32 çağrıları (aktif pencere + boşta süresi) ---
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PcmNative {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [DllImport("kernel32.dll")] public static extern uint GetTickCount();
}
"@

function Get-IdleMs {
  $lii = New-Object PcmNative+LASTINPUTINFO
  $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
  [void][PcmNative]::GetLastInputInfo([ref]$lii)
  return [PcmNative]::GetTickCount() - $lii.dwTime
}

function Get-ForegroundApp {
  $h = [PcmNative]::GetForegroundWindow()
  if ($h -eq [IntPtr]::Zero) { return $null }
  [uint32]$procId = 0
  [void][PcmNative]::GetWindowThreadProcessId($h, [ref]$procId)
  if ($procId -le 0) { return $null }
  $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $proc) { return $null }
  $sb = New-Object System.Text.StringBuilder 512
  [void][PcmNative]::GetWindowText($h, $sb, 512)
  return [pscustomobject]@{ App = $proc.ProcessName; Title = $sb.ToString() }
}

# --- Görünür tray ikonu (şeffaflık) ---
try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $script:Tray = New-Object System.Windows.Forms.NotifyIcon
  $script:Tray.Icon = [System.Drawing.SystemIcons]::Information
  $script:Tray.Text = 'Deniz PC Monitör — aktivite kaydı açık'
  $script:Tray.Visible = $true
  $script:Tray.ShowBalloonTip(8000, 'Deniz PC Monitör', 'Bu bilgisayarda aktivite kaydı açık (yönetim bilgilendirmesi).', [System.Windows.Forms.ToolTipIcon]::Info)
} catch { }

# --- Güç olaylarını oku (açılma/kapanma/uyku) ---
function Get-PowerEvents([datetime]$since) {
  $out = @()
  try {
    Get-WinEvent -FilterHashtable @{ LogName='System'; Id=@(1074,6006,6008,42,107); StartTime=$since } -ErrorAction SilentlyContinue | ForEach-Object {
      $sub = switch ($_.Id) {
        42   { 'SLEEP' }
        107  { 'WAKE' }
        1074 { 'OFF' }
        6006 { 'OFF' }
        6008 { 'OFF' }
        default { $null }
      }
      if ($sub) {
        $out += @{ type='POWER'; subtype=$sub; occurredAt=$_.TimeCreated.ToUniversalTime().ToString('o') }
      }
    }
  } catch { }
  return $out
}

# --- Durum ---
$usage = @{}                 # app -> saniye
$titles = @{}                # app -> son pencere başlığı
$launched = @{}              # bu oturumda açılış kaydı verilen app'ler
$pending = New-Object System.Collections.ArrayList   # gönderilemeyen olaylar
$lastPowerCheck = (Get-Date).AddMinutes(-15)
# İlk gönderim ~60 sn sonra olsun ki cihaz CRM'de hemen görünsün
$lastSend = (Get-Date).AddSeconds([Math]::Max(0, $SendSeconds - 60))

# Açılış: boot zamanını POWER ON olarak bir kez gönder
try {
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  [void]$pending.Add(@{ type='POWER'; subtype='ON'; occurredAt=([datetime]$boot).ToUniversalTime().ToString('o') })
} catch { }

Write-Host "Deniz PC Monitör çalışıyor. Cihaz: $DeviceName ($DeviceId) -> $ServerUrl" -ForegroundColor Green

function Send-Batch {
  $events = New-Object System.Collections.ArrayList
  # Bekleyen (güç / açılış) olayları
  foreach ($e in $pending) { [void]$events.Add($e) }
  # Güç olayları
  $nowCheck = Get-Date
  foreach ($pe in (Get-PowerEvents $lastPowerCheck)) { [void]$events.Add($pe) }
  # Uygulama süreleri
  $nowIso = (Get-Date).ToUniversalTime().ToString('o')
  foreach ($app in $usage.Keys) {
    if ($usage[$app] -gt 0) {
      [void]$events.Add(@{ type='APP_USAGE'; app=$app; title=[string]$titles[$app]; durationSec=[int]$usage[$app]; occurredAt=$nowIso })
    }
  }
  if ($events.Count -eq 0) { $script:lastPowerCheck = $nowCheck; return }

  $body = @{ deviceId=$DeviceId; deviceName=$DeviceName; events=@($events) } | ConvertTo-Json -Depth 6
  try {
    Invoke-RestMethod -Uri $IngestUrl -Method Post -Body $body -ContentType 'application/json' -Headers @{ 'X-Pc-Token'=$Token } -TimeoutSec 30 | Out-Null
    Write-Host ("{0}  gönderildi: {1} olay" -f (Get-Date -Format 'HH:mm:ss'), $events.Count) -ForegroundColor DarkGray
    # Başarılı: durumu sıfırla
    $script:usage = @{}
    $script:titles = @{}
    $script:pending.Clear()
    $script:lastPowerCheck = $nowCheck
  } catch {
    Write-Host ("{0}  gönderim hatası: {1} (tekrar denenecek)" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) -ForegroundColor Yellow
    # Güç/açılış olaylarını pending'e taşı ki kaybolmasın (süreler birikmeye devam eder)
    foreach ($pe in (Get-PowerEvents $lastPowerCheck)) { [void]$script:pending.Add($pe) }
    $script:lastPowerCheck = $nowCheck
  }
}

# İlk kurulumda beklemeden hemen gönder: cihaz + açılış anında CRM'de görünsün.
# İlk aktif pencereyi de bir kez örnekleyip gönderelim.
try {
  if ((Get-IdleMs) -lt ($IdleSeconds * 1000)) {
    $fg0 = Get-ForegroundApp
    if ($fg0 -and $fg0.App) {
      $usage[$fg0.App] = $SampleSeconds
      $titles[$fg0.App] = $fg0.Title
      $launched[$fg0.App] = $true
      [void]$pending.Add(@{ type='APP_LAUNCH'; app=$fg0.App; occurredAt=(Get-Date).ToUniversalTime().ToString('o') })
    }
  }
} catch { }
Send-Batch
$lastSend = Get-Date

# --- Ana döngü ---
while ($true) {
  try {
    if ((Get-IdleMs) -lt ($IdleSeconds * 1000)) {
      $fg = Get-ForegroundApp
      if ($fg -and $fg.App) {
        if (-not $usage.ContainsKey($fg.App)) { $usage[$fg.App] = 0 }
        $usage[$fg.App] += $SampleSeconds
        $titles[$fg.App] = $fg.Title
        if (-not $launched.ContainsKey($fg.App)) {
          $launched[$fg.App] = $true
          [void]$pending.Add(@{ type='APP_LAUNCH'; app=$fg.App; occurredAt=(Get-Date).ToUniversalTime().ToString('o') })
        }
      }
    }
  } catch { }

  if (((Get-Date) - $lastSend).TotalSeconds -ge $SendSeconds) {
    Send-Batch
    $lastSend = Get-Date
  }
  Start-Sleep -Seconds $SampleSeconds
}
