# Copy Dell OMSA 9.5.0 SysMgmtx64.msi and stop it from installing only the
# remote console on Windows 10. Also keeps the package's disk-filter and
# Broadcom NIC drivers out. Does not run the install. Does not modify SourceMsi.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $SourceMsi,
  [Parameter(Mandatory = $true)]
  [string] $DestMsi
)

$ErrorActionPreference = 'Stop'

$expectedVersion = '9.5.0'
$expectedCode = '{4C7F1FB4-0A86-4309-B706-7F9659285F89}'
$keepBmapi = 'BMAPIa.dll.945AC698_14D6_4E08_8866_F0E8DE5CE895'

function Test-BlockedComponent([string] $name) {
  if ($name -eq $keepBmapi) { return $false }
  if ($name -like 'swraid_*') { return $true }
  if ($name -like 'Marvel*') { return $true }
  if ($name -like 'afamgt.sys.*') { return $true }
  if ($name -like 'addfilter.exe.*') { return $true }
  if ($name -like 'basfnd.sys.*') { return $true }
  if ($name -like 'BMAPIa.dll.*') { return $true }
  if ($name -eq 'reg_data.39441429_5736_400C_8E92_F77C9EB26001') { return $true }
  return $false
}

$sourceFull = [IO.Path]::GetFullPath($SourceMsi)
$destFull = [IO.Path]::GetFullPath($DestMsi)
if (-not (Test-Path -LiteralPath $sourceFull)) {
  throw "Source MSI not found: $sourceFull"
}
if ($sourceFull -eq $destFull) {
  throw 'DestMsi must be a different file. The signed original stays untouched.'
}
if (Test-Path -LiteralPath $destFull) {
  throw "DestMsi already exists: $destFull"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destFull) | Out-Null
Copy-Item -LiteralPath $sourceFull -Destination $destFull
$created = $true

try {
  $installer = New-Object -ComObject WindowsInstaller.Installer
  $db = $installer.OpenDatabase($destFull, 1)

  $prop = $db.OpenView('SELECT Property, Value FROM Property')
  $prop.Execute()
  $version = $null
  $code = $null
  while ($true) {
    $row = $prop.Fetch()
    if ($null -eq $row) { break }
    $key = [string]$row.StringData(1)
    if ($key -eq 'ProductVersion') { $version = [string]$row.StringData(2) }
    if ($key -eq 'ProductCode') { $code = [string]$row.StringData(2) }
  }
  $prop.Close()
  if ($version -ne $expectedVersion -or $code -ne $expectedCode) {
    throw "This script is for OMSA $expectedVersion $expectedCode. This MSI is $version $code."
  }

  $seenKeep = $false
  $names = New-Object System.Collections.Generic.List[string]
  $storelibBefore = New-Object System.Collections.Generic.List[string]
  $comp = $db.OpenView('SELECT Component, Condition FROM Component')
  $comp.Execute()
  while ($true) {
    $row = $comp.Fetch()
    if ($null -eq $row) { break }
    $name = [string]$row.StringData(1)
    $condition = [string]$row.StringData(2)
    $names.Add($name)
    if ($name -eq $keepBmapi) { $seenKeep = $true }
    if ($name -like 'storelibit.dll.*') {
      $storelibBefore.Add($name + '=' + $condition)
    }
  }
  $comp.Close()
  if (-not $seenKeep) {
    throw "Expected Server Instrumentation library $keepBmapi is not in this MSI. Refusing to patch."
  }
  if ($storelibBefore.Count -lt 1) {
    throw 'storelibit.dll is not in this MSI. Refusing to patch.'
  }

  $del = $db.OpenView('DELETE FROM Condition WHERE Level=0')
  $del.Execute()
  $del.Close()

  $blocked = 0
  foreach ($name in $names) {
    if (-not (Test-BlockedComponent $name)) { continue }
    $safe = $name.Replace("'", "''")
    $sql = "UPDATE ``Component`` SET ``Condition``='0' WHERE ``Component``='$safe'"
    $upd = $db.OpenView($sql)
    $upd.Execute()
    $upd.Close()
    $blocked++
  }

  # Read the edits back before Commit. Opening the same MSI again in this
  # process after Commit fails, so the check has to happen on this database.
  $left = $db.OpenView('SELECT Feature_ FROM Condition WHERE Level=0')
  $left.Execute()
  $levelZero = 0
  while ($true) {
    $row = $left.Fetch()
    if ($null -eq $row) { break }
    $levelZero++
  }
  $left.Close()

  $again = $db.OpenView('SELECT Component, Condition FROM Component')
  $again.Execute()
  $stillBlocked = 0
  $keepCondition = $null
  $storelibAfter = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $row = $again.Fetch()
    if ($null -eq $row) { break }
    $name = [string]$row.StringData(1)
    $condition = [string]$row.StringData(2)
    if ($name -eq $keepBmapi) { $keepCondition = $condition }
    if ($name -like 'storelibit.dll.*') { $storelibAfter.Add($name + '=' + $condition) }
    if ((Test-BlockedComponent $name) -and $condition -eq '0') { $stillBlocked++ }
  }
  $again.Close()

  if ($levelZero -ne 0) { throw "Level=0 feature conditions still present: $levelZero" }
  if ($stillBlocked -ne $blocked) { throw "Blocked components = $stillBlocked, expected $blocked" }
  if ($keepCondition -ne '') { throw "Refusing result: $keepBmapi condition is [$keepCondition]" }
  if (($storelibBefore -join '|') -ne ($storelibAfter -join '|')) {
    throw 'storelibit.dll condition changed. That library has to stay as Dell shipped it.'
  }

  $db.Commit()
  $created = $false

  $log = Join-Path $env:TEMP 'omsa-win10-install.log'
  Write-Output "Patched $destFull"
  Write-Output "Blocked driver components: $stillBlocked"
  Write-Output 'Feature conditions that force level 0: removed'
  Write-Output ''
  Write-Output 'Install from an elevated prompt, after uninstalling a stock copy of this same product:'
  Write-Output ('msiexec.exe /i "{0}" ADDLOCAL=IWS,SI,MgmtInt,CLI,WMI,OSLOG,OMSS,NICInt,BRCM,INTEL,SNMP,RmtMgmt,iDRAC12G INSTALLLEVEL=0 REBOOT=ReallySuppress /qn /l*v "{1}"' -f $destFull, $log)
}
catch {
  if ($created -and (Test-Path -LiteralPath $destFull)) {
    Remove-Item -LiteralPath $destFull -Force
  }
  throw
}
