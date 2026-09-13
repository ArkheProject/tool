@echo off
echo Arkhe Simple Hidden NIC
net session >nul 2>&1 || (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    exit /b 0
)

set "BATFILE=%~f0"
set "PS1=%TEMP%\nic-hidden-%RANDOM%.ps1"

powershell -NoProfile -Command "$m='#PS'+'START#'; ((Get-Content -LiteralPath $env:BATFILE -Raw) -split $m,2)[1] | Set-Content -LiteralPath $env:PS1 -Encoding UTF8"
if not exist "%PS1%" exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%ERRORLEVEL%"
del "%PS1%" >nul 2>&1
exit /b %RC%

#PSSTART#
$ErrorActionPreference = 'Stop'
$class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

$dir = Join-Path $env:ProgramData 'nic-hidden'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $dir "log-$stamp.txt"
$bak   = Join-Path $dir "restore-$stamp.ps1"
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c; Add-Content -LiteralPath $log -Value $m }

Say "nic-hidden  $(Get-Date)"

# restarting the adapter under RDP drops the session and the machine is unreachable
if ($env:SESSIONNAME -like 'RDP*') { Say 'ABORT: remote session.' Red; exit 2 }

# ---------------- rules: intent by name, vendor agnostic ----------------
$rules = @(
  @{ Pat='GreenEthernet|AdvancedEEE|GigaLite|PowerSav|ULPMode|SipsEnabled|ReduceSpeedOnPowerDown|AutoDisableGigabit|EnergyEfficient|LowPowerIdle|IdlePowerSave|AutoPowerSaveModeEnabled'
     V=0; N='PHY / idle power saving off' }
  @{ Pat='WakeOn|S5WakeOnLan|WakeOnManagment|OnTCO'
     V=0; N='wake source off' }
  @{ Pat='DeviceSleepOnDisconnect'
     V=0; N='no D3 on link loss' }
  @{ Pat='MulticastFilterType'
     V=0; N='perfect MAC filter, not hash' }
  @{ Pat='IntDelay|MinimumInterruptInterval|InterruptModeration|InterruptInterval|Coalesc|^ITR$'
     V=0; N='interrupt moderation off' }
  @{ Pat='WaitAutoNegComplete'
     V=0; N='do not block init on autoneg' }

  # V=$null: not written. *NdisDeviceType breaks Network Location Awareness
  # without dropping link, so the rollback check below cannot detect it.
  # PciScanMethod can leave the miniport unable to initialize. Queue counts
  # need an RSS core count this script does not have.
  @{ Pat='PciScanMethod|PollForLinkStatus|WaitLinkTimeOut|NdisDeviceType|LinkNegotiationProcess|NumRxQueues|NumTxQueues|NumRssQueues'
     V=$null; N='unrecoverable or needs context, not written' }
)
$rulePat = ($rules | ForEach-Object { $_.Pat }) -join '|'

# NDIS descriptors and INF metadata sit in the class key but are not tunables
$noise = '^\*?(PS[A-Za-z]+|Driver.*|Infe?.*|Net(Cfg|LuidIndex|work).*|ComponentId|CoInstallers32|Match.*|Provider.*|Bus.*|Characteristics|IfType|IfTypePreStart|InstallTimeStamp|LinkageInstallTime|MediaType|PhysicalMediaType|InstanceId|DeviceInstanceID|IncludedInfs|BootFlags|EventMessageFile|TypesSupported|Service)$'

$nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -eq 'Up' -and $_.InterfaceType -eq 6 -and $_.HardwareInterface -and -not $_.Virtual -and
    $_.InterfaceDescription -notmatch 'Virtual|Hyper-V|VMware|VirtualBox|Loopback|Bluetooth|TAP|WAN Miniport|Wi-?Fi|Wireless|802\.11'
})
if (-not $nics) { Say 'No eligible wired adapter.' Yellow; exit 0 }

$undo = @('# nic-hidden restore'); $changed = 0

foreach ($nic in $nics) {
  $ck = Get-ChildItem $class | Where-Object {
      (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).NetCfgInstanceId -eq $nic.InterfaceGuid } | Select-Object -First 1
  if (-not $ck) { continue }

  $p  = $ck.PSPath
  $cp = Get-ItemProperty $p
  $speedBefore = $nic.LinkSpeed

  # a keyword with an Ndi\Params subkey renders in the Advanced tab: not ours
  $exposed = @(Get-ChildItem "$p\Ndi\Params" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)

  Say ''
  Say "=== $($nic.Name)  [$($nic.InterfaceDescription)]  $speedBefore" White
  Say "    $($nic.DriverFileName) $($nic.DriverVersion)  $($nic.DriverProvider)"

  # ---- discovery: three sources ----
  $inReg = @($cp.PSObject.Properties | ForEach-Object { $_.Name })

  # NdisReadConfiguration / NetConfigurationQueryUlong take a UTF-16 keyword.
  # Not a wide string in the image => the driver can never read it.
  $inImage = @()
  $drv = "$env:WINDIR\System32\drivers\$($nic.DriverFileName)"
  if (Test-Path $drv) {
      $b = [IO.File]::ReadAllBytes($drv)
      $set = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($off in 0,1) {
          $len = $b.Length - $off; $len -= $len % 2
          foreach ($m in [regex]::Matches([Text.Encoding]::Unicode.GetString($b,$off,$len),'\*?[A-Z][A-Za-z0-9_]{3,40}')) { [void]$set.Add($m.Value) }
      }
      $inImage = @($set)
  }

  $inInf = @()
  if ($cp.InfPath -and (Test-Path "$env:WINDIR\INF\$($cp.InfPath)")) {
      $inInf = @(Select-String "$env:WINDIR\INF\$($cp.InfPath)" -Pattern '^\s*HKR\s*,\s*,\s*([^,\s]+)\s*,' -AllMatches |
                 ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value.Trim('"') })
  }

  $hidden = @($inReg + ($inImage | Where-Object { $_ -cmatch $rulePat }) + $inInf |
              Where-Object { $exposed -notcontains $_ -and $_ -notmatch $noise } | Sort-Object -Unique)

  Say "    hidden: $($hidden.Count)   exposed in Advanced tab: $($exposed.Count)  (untouched)"
  Say ''

  $nicUndo = @()
  foreach ($k in $hidden) {
      if ($k -eq 'PnPCapabilities') { continue }   # handled below, OR not assign
      $r = $rules | Where-Object { $k -cmatch $_.Pat } | Select-Object -First 1
      if (-not $r) {
          $v = if ($null -ne $cp.$k) { $cp.$k } else { '<unset>' }
          Say ("  ? {0,-38} {1}   unclassified, not written" -f $k, $v) DarkGray; continue
      }
      if ($null -eq $r.V) { Say ("  x {0,-38} {1}" -f $k, $r.N) Magenta; continue }

      $exists = $null -ne $cp.$k
      $cur    = if ($exists) { $cp.$k } else { '<unset>' }
      if ($exists -and "$cur" -eq "$($r.V)") { Say ("  = {0,-38} already {1}" -f $k, $r.V) DarkGray; continue }

      # existing values keep their kind. seeding: '_' means a NetAdapterCx group
      # property read as REG_DWORD; no '_' means a classic NDIS keyword, REG_SZ.
      $kind = if ($exists) { (Get-Item $p).GetValueKind($k) } elseif ($k -match '_') { 'DWord' } else { 'String' }
      if ($exists) { $nicUndo += "Set-ItemProperty -LiteralPath '$p' -Name '$k' -Value '$cur'" }
      else         { $nicUndo += "Remove-ItemProperty -LiteralPath '$p' -Name '$k' -ErrorAction SilentlyContinue" }

      try {
          if ("$kind" -eq 'DWord') { New-ItemProperty -LiteralPath $p -Name $k -Value ([int]$r.V) -PropertyType DWord -Force | Out-Null }
          else                     { New-ItemProperty -LiteralPath $p -Name $k -Value "$($r.V)" -PropertyType String -Force | Out-Null }
          Say ("  + {0,-38} {1} -> {2}  [{3}]" -f $k, $cur, $r.V, $kind) Green
          $changed++
      } catch { Say ("  ! {0,-38} write failed" -f $k) Red }
  }

  # PnPCapabilities is hidden but read by the PnP manager, not the miniport.
  # REG_DWORD bitfield: OR in 0x18, never assign, or vendor bits get cleared.
  $pnp = 0; [void][int]::TryParse("$($cp.PnPCapabilities)", [ref]$pnp)
  $new = $pnp -bor 24
  if ($new -ne $pnp) {
      $nicUndo += "Set-ItemProperty -LiteralPath '$p' -Name 'PnPCapabilities' -Value $pnp"
      New-ItemProperty -LiteralPath $p -Name PnPCapabilities -Value $new -PropertyType DWord -Force | Out-Null
      Say ("  + {0,-38} {1} -> {2}" -f 'PnPCapabilities', $pnp, $new) Green
      $changed++
  } else { Say ("  = {0,-38} already {1}" -f 'PnPCapabilities', $pnp) DarkGray }

  if (-not $nicUndo) { continue }
  $undo += $nicUndo

  # ---- restart, verify, revert this adapter if the link regressed ----
  Restart-NetAdapter -Name $nic.Name -Confirm:$false
  $deadline = (Get-Date).AddSeconds(60)
  do { Start-Sleep -Seconds 2; $now = Get-NetAdapter -Name $nic.Name -ErrorAction SilentlyContinue }
  while ($now.Status -ne 'Up' -and (Get-Date) -lt $deadline)

  $bad = ($now.Status -ne 'Up') -or ($speedBefore -match '^\d' -and $now.LinkSpeed -ne $speedBefore)
  if ($bad) {
      Say "  ROLLBACK: $($now.Status) $($now.LinkSpeed), was $speedBefore" Red
      foreach ($line in $nicUndo) { try { Invoke-Expression $line } catch {} }
      Restart-NetAdapter -Name $nic.Name -Confirm:$false
      Start-Sleep -Seconds 8
      $now = Get-NetAdapter -Name $nic.Name -ErrorAction SilentlyContinue
      Say "  restored: $($now.Status) $($now.LinkSpeed)" Yellow
      $undo = $undo | Where-Object { $nicUndo -notcontains $_ }
      $changed -= $nicUndo.Count
  } else {
      Say "  link: $($now.Status) $($now.LinkSpeed)" Green
  }
}

if ($changed -le 0) { Say "`nNothing to change. Hidden keywords were already correct." Yellow; exit 0 }

$undo | Set-Content -LiteralPath $bak -Encoding ASCII
Say ''
Say "Changed $changed value(s)."
Say "Log:  $log"
Say "Undo: powershell -File `"$bak`""
pause
