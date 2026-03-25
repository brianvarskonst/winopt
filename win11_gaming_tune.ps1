#requires -RunAsAdministrator
<#
.SYNOPSIS
  Windows 11 gaming optimization script with backup and restore support.

.DESCRIPTION
  The script focuses on stable Windows gaming tweaks instead of blindly
  disabling large parts of the OS. It can:

  - back up the current state of touched services, registry values, tasks,
    and the active power plan
  - apply safe or more aggressive background-service reductions
  - disable Game DVR capture, enable Game Mode, disable mouse acceleration,
    turn off power throttling, and switch to Ultimate Performance
  - optionally disable bundles such as Xbox, Bluetooth, Print, Touch, Search,
    Remote Discovery, and VBS/HVCI
  - restore everything the script changed from the backup JSON

.EXAMPLE
  PowerShell.exe -ExecutionPolicy Bypass -File .\win11_gaming_tune.ps1 -Mode Optimize -Profile Safe

.EXAMPLE
  PowerShell.exe -ExecutionPolicy Bypass -File .\win11_gaming_tune.ps1 -Mode Optimize -Profile Aggressive -DisableXboxServices -DisableRemoteDiscoveryServices -DisableSearchIndexing -DisableVbs

.EXAMPLE
  PowerShell.exe -ExecutionPolicy Bypass -File .\win11_gaming_tune.ps1 -Mode Optimize -Profile Aggressive -Cs2Mode -DisableXboxServices -DisableRemoteDiscoveryServices -DisableSearchIndexing

.EXAMPLE
  PowerShell.exe -ExecutionPolicy Bypass -File .\win11_gaming_tune.ps1 -Mode Restore
#>

[CmdletBinding()]
param(
    [ValidateSet("Optimize", "Restore")]
    [string]$Mode = "Optimize",

    [ValidateSet("Safe", "Aggressive")]
    [string]$Profile = "Safe",

    [string]$BackupPath,

    [switch]$DisableBluetoothServices,
    [switch]$DisablePrintServices,
    [switch]$DisableTouchServices,
    [switch]$DisableXboxServices,
    [switch]$DisableSearchIndexing,
    [switch]$DisableRemoteDiscoveryServices,
    [switch]$DisableVbs,
    [switch]$Cs2Mode,
    [switch]$SkipRestorePoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $BackupPath) {
    $BackupPath = Join-Path $ScriptRoot "win11_gaming_tune_backup.json"
}

$script:Backup = [ordered]@{
    ScriptVersion     = "1.1"
    CreatedUtc        = (Get-Date).ToUniversalTime().ToString("o")
    ComputerName      = $env:COMPUTERNAME
    ActivePowerScheme = $null
    PowerSettings     = @()
    Services          = @()
    Registry          = @()
    ScheduledTasks    = @()
    BcdSettings       = @()
}

$script:SeenServices = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:SeenRegistry = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:SeenTasks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:SeenBcdSettings = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:SeenPowerSettings = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:PowerSettingGuids = @{
    SUB_USB         = "2a737441-1930-4402-8d77-b2bebba308a3"
    USBSELECTIVE    = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
    SUB_PCIEXPRESS  = "501a4d13-42af-4429-9fd1-a8218c268e20"
    ASPM            = "ee12f906-d277-404b-b6da-e5fa1a576df5"
    SUB_PROCESSOR   = "54533251-82be-4824-96c1-47b60b740d00"
    PROCTHROTTLEMIN = "893dee8e-2bef-41e0-89c6-b55d0929964c"
    PROCTHROTTLEMAX = "bc5038f7-23e0-4960-96da-33abaf5935ec"
    PERFEPP         = "36687f9e-e3a5-4dbf-b1dc-15eb381c6863"
    CPMINCORES      = "0cc5b647-c1df-4637-891a-dec35c318583"
    CPMAXCORES      = "ea062031-0e34-4ff1-9b6d-eb1059334028"
    PERFBOOSTMODE   = "be337238-0d82-4146-a960-4f3749d470c7"
}
$script:PowerPlanGuids = @{
    ULTIMATE_PERFORMANCE = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    HIGH_PERFORMANCE     = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
}

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Message) -ForegroundColor Cyan
}

function Write-InfoLine {
    param([string]$Message)
    Write-Host ("[+] {0}" -f $Message) -ForegroundColor Green
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host ("[!] {0}" -f $Message) -ForegroundColor Yellow
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-BackupFile {
    $backupDirectory = Split-Path -Path $BackupPath -Parent
    if ($backupDirectory -and -not (Test-Path -Path $backupDirectory)) {
        New-Item -Path $backupDirectory -ItemType Directory -Force | Out-Null
    }

    $script:Backup.CreatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    $json = $script:Backup | ConvertTo-Json -Depth 8
    Set-Content -Path $BackupPath -Value $json -Encoding UTF8
}

function Get-BackupFileContent {
    if (-not (Test-Path -Path $BackupPath)) {
        throw "Backup file not found: $BackupPath"
    }

    return Get-Content -Path $BackupPath -Raw | ConvertFrom-Json
}

function Get-ActivePowerSchemeGuid {
    $output = powercfg /GETACTIVESCHEME 2>$null
    if ($output -match "([0-9A-Fa-f-]{36})") {
        return $Matches[1]
    }

    return $null
}

function Resolve-PowerIdentifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identifier
    )

    if ($Identifier -match "^[0-9A-Fa-f-]{36}$") {
        return $Identifier.ToLowerInvariant()
    }

    $key = $Identifier.ToUpperInvariant()
    if ($script:PowerSettingGuids.ContainsKey($key)) {
        return $script:PowerSettingGuids[$key]
    }

    throw "Unknown power identifier: $Identifier"
}

function Backup-PowerSettingConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SchemeGuid,

        [Parameter(Mandatory = $true)]
        [string]$Subgroup,

        [Parameter(Mandatory = $true)]
        [string]$Setting
    )

    $resolvedSubgroup = Resolve-PowerIdentifier -Identifier $Subgroup
    $resolvedSetting = Resolve-PowerIdentifier -Identifier $Setting
    $id = "$SchemeGuid|$resolvedSubgroup|$resolvedSetting"

    if ($script:SeenPowerSettings.Contains($id)) {
        return
    }

    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$SchemeGuid\$resolvedSubgroup\$resolvedSetting"
    $acExists = $false
    $acValue = $null
    $dcExists = $false
    $dcValue = $null

    if (Test-Path -Path $path) {
        $properties = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        if ($properties -and $properties.PSObject.Properties.Match("ACSettingIndex").Count -gt 0) {
            $acExists = $true
            $acValue = [int]$properties.ACSettingIndex
        }

        if ($properties -and $properties.PSObject.Properties.Match("DCSettingIndex").Count -gt 0) {
            $dcExists = $true
            $dcValue = [int]$properties.DCSettingIndex
        }
    }

    $null = $script:SeenPowerSettings.Add($id)
    $script:Backup.PowerSettings += [pscustomobject]@{
        SchemeGuid   = $SchemeGuid
        SubgroupGuid = $resolvedSubgroup
        SettingGuid  = $resolvedSetting
        AcExists     = $acExists
        AcValue      = $acValue
        DcExists     = $dcExists
        DcValue      = $dcValue
    }
}

function Set-PowerSettingValueEx {
    param(
        [string]$Scheme = "SCHEME_CURRENT",

        [Parameter(Mandatory = $true)]
        [string]$Subgroup,

        [Parameter(Mandatory = $true)]
        [string]$Setting,

        [Nullable[int]]$AcValue,

        [Nullable[int]]$DcValue
    )

    $schemeGuid = if ($Scheme -eq "SCHEME_CURRENT") { Get-ActivePowerSchemeGuid } else { $Scheme }
    if (-not $schemeGuid) {
        throw "Could not resolve the active power scheme."
    }

    $resolvedSubgroup = Resolve-PowerIdentifier -Identifier $Subgroup
    $resolvedSetting = Resolve-PowerIdentifier -Identifier $Setting

    Backup-PowerSettingConfiguration -SchemeGuid $schemeGuid -Subgroup $resolvedSubgroup -Setting $resolvedSetting

    if ($PSBoundParameters.ContainsKey("AcValue") -and $null -ne $AcValue) {
        powercfg /SETACVALUEINDEX $Scheme $resolvedSubgroup $resolvedSetting ([int]$AcValue) | Out-Null
        Write-InfoLine ("Power setting AC: {0}/{1} = {2}" -f $Subgroup, $Setting, $AcValue)
    }

    if ($PSBoundParameters.ContainsKey("DcValue") -and $null -ne $DcValue) {
        powercfg /SETDCVALUEINDEX $Scheme $resolvedSubgroup $resolvedSetting ([int]$DcValue) | Out-Null
        Write-InfoLine ("Power setting DC: {0}/{1} = {2}" -f $Subgroup, $Setting, $DcValue)
    }

    powercfg /SETACTIVE $schemeGuid | Out-Null
}

function Restore-PowerSettingConfiguration {
    param([Parameter(Mandatory = $true)]$Entry)

    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$($Entry.SchemeGuid)\$($Entry.SubgroupGuid)\$($Entry.SettingGuid)"

    if ($Entry.AcExists) {
        powercfg /SETACVALUEINDEX $Entry.SchemeGuid $Entry.SubgroupGuid $Entry.SettingGuid ([int]$Entry.AcValue) | Out-Null
    }
    elseif (Test-Path -Path $path) {
        Remove-ItemProperty -Path $path -Name "ACSettingIndex" -ErrorAction SilentlyContinue
    }

    if ($Entry.DcExists) {
        powercfg /SETDCVALUEINDEX $Entry.SchemeGuid $Entry.SubgroupGuid $Entry.SettingGuid ([int]$Entry.DcValue) | Out-Null
    }
    elseif (Test-Path -Path $path) {
        Remove-ItemProperty -Path $path -Name "DCSettingIndex" -ErrorAction SilentlyContinue
    }

    powercfg /SETACTIVE $Entry.SchemeGuid | Out-Null
    Write-InfoLine ("Power setting restored: {0}/{1}" -f $Entry.SubgroupGuid, $Entry.SettingGuid)
}

function Backup-RegistryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $id = "$Path|$Name"
    if ($script:SeenRegistry.Contains($id)) {
        return
    }

    $exists = $false
    $kind = $null
    $value = $null

    if (Test-Path -Path $Path) {
        $item = Get-Item -Path $Path
        if ($item.Property -contains $Name) {
            $exists = $true
            $kind = [string]$item.GetValueKind($Name)
            $value = Get-ItemPropertyValue -Path $Path -Name $Name
        }
    }

    $null = $script:SeenRegistry.Add($id)
    $script:Backup.Registry += [pscustomobject]@{
        Path   = $Path
        Name   = $Name
        Exists = $exists
        Kind   = $kind
        Value  = $value
    }
}

function Set-RegistryValueEx {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("String", "ExpandString", "MultiString", "Binary", "DWord", "QWord")]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    Backup-RegistryValue -Path $Path -Name $Name

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
    Write-InfoLine ("Registry set: {0}\{1} = {2}" -f $Path, $Name, $Value)
}

function Restore-RegistryValue {
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not (Test-Path -Path $Entry.Path)) {
        New-Item -Path $Entry.Path -Force | Out-Null
    }

    if ($Entry.Exists) {
        $type = if ($Entry.Kind) { [string]$Entry.Kind } else { "String" }
        New-ItemProperty -Path $Entry.Path -Name $Entry.Name -PropertyType $type -Value $Entry.Value -Force | Out-Null
        Write-InfoLine ("Registry restored: {0}\{1}" -f $Entry.Path, $Entry.Name)
    }
    else {
        Remove-ItemProperty -Path $Entry.Path -Name $Entry.Name -ErrorAction SilentlyContinue
        Write-InfoLine ("Registry removed: {0}\{1}" -f $Entry.Path, $Entry.Name)
    }
}

function Resolve-ServiceNames {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    $names = foreach ($pattern in $Patterns) {
        Get-Service -Name $pattern -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    }

    return $names | Sort-Object -Unique
}

function Backup-ServiceConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($script:SeenServices.Contains($Name)) {
        return
    }

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }

    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $startValue = $null
    $delayedValue = $null

    if (Test-Path -Path $serviceKey) {
        $serviceProps = Get-ItemProperty -Path $serviceKey
        $startValue = $serviceProps.Start
        $delayedValue = (Get-ItemProperty -Path $serviceKey -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart
    }

    $null = $script:SeenServices.Add($Name)
    $script:Backup.Services += [pscustomobject]@{
        Name             = $Name
        Start            = $startValue
        DelayedAutostart = $delayedValue
        Status           = [string]$service.Status
    }
}

function Set-ServiceStartupEx {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$NamePattern,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Automatic", "Manual", "Disabled")]
        [string]$StartupType,

        [switch]$StopIfRunning
    )

    foreach ($serviceName in (Resolve-ServiceNames -Patterns $NamePattern)) {
        Backup-ServiceConfiguration -Name $serviceName

        try {
            Set-Service -Name $serviceName -StartupType $StartupType -ErrorAction Stop
        }
        catch {
            Write-WarnLine ("Could not change service {0}: {1}" -f $serviceName, $_.Exception.Message)
            continue
        }

        $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
        if (Test-Path -Path $serviceKey) {
            if ($StartupType -eq "Automatic") {
                New-ItemProperty -Path $serviceKey -Name DelayedAutostart -PropertyType DWord -Value 0 -Force | Out-Null
            }
            else {
                Remove-ItemProperty -Path $serviceKey -Name DelayedAutostart -ErrorAction SilentlyContinue
            }
        }

        if ($StopIfRunning) {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        }

        Write-InfoLine ("Service set: {0} -> {1}" -f $serviceName, $StartupType)
    }
}

function Restore-ServiceConfiguration {
    param([Parameter(Mandatory = $true)]$Entry)

    $serviceName = [string]$Entry.Name
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }

    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    $startValue = if ($null -ne $Entry.Start) { [int]$Entry.Start } else { $null }

    switch ($startValue) {
        2 {
            Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
            if (Test-Path -Path $serviceKey) {
                if ($null -ne $Entry.DelayedAutostart) {
                    New-ItemProperty -Path $serviceKey -Name DelayedAutostart -PropertyType DWord -Value ([int]$Entry.DelayedAutostart) -Force | Out-Null
                }
                else {
                    Remove-ItemProperty -Path $serviceKey -Name DelayedAutostart -ErrorAction SilentlyContinue
                }
            }
        }
        3 {
            Set-Service -Name $serviceName -StartupType Manual -ErrorAction SilentlyContinue
            if (Test-Path -Path $serviceKey) {
                Remove-ItemProperty -Path $serviceKey -Name DelayedAutostart -ErrorAction SilentlyContinue
            }
        }
        4 {
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
            if (Test-Path -Path $serviceKey) {
                Remove-ItemProperty -Path $serviceKey -Name DelayedAutostart -ErrorAction SilentlyContinue
            }
        }
        default {
            if (Test-Path -Path $serviceKey -and $null -ne $startValue) {
                New-ItemProperty -Path $serviceKey -Name Start -PropertyType DWord -Value $startValue -Force | Out-Null
                if ($null -ne $Entry.DelayedAutostart) {
                    New-ItemProperty -Path $serviceKey -Name DelayedAutostart -PropertyType DWord -Value ([int]$Entry.DelayedAutostart) -Force | Out-Null
                }
                else {
                    Remove-ItemProperty -Path $serviceKey -Name DelayedAutostart -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($Entry.Status -eq "Running" -and $startValue -ne 4) {
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    }

    Write-InfoLine ("Service restored: {0}" -f $serviceName)
}

function Backup-ScheduledTaskState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskPath,

        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    $id = "$TaskPath|$TaskName"
    if ($script:SeenTasks.Contains($id)) {
        return
    }

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
    }
    catch {
        return
    }

    $null = $script:SeenTasks.Add($id)
    $script:Backup.ScheduledTasks += [pscustomobject]@{
        TaskPath = $TaskPath
        TaskName = $TaskName
        Enabled  = [bool]$task.Settings.Enabled
    }
}

function Set-ScheduledTaskEnabledState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskPath,

        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [bool]$Enabled
    )

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
    }
    catch {
        return
    }

    Backup-ScheduledTaskState -TaskPath $TaskPath -TaskName $TaskName

    if ($Enabled) {
        Enable-ScheduledTask -InputObject $task | Out-Null
        Write-InfoLine ("Scheduled task enabled: {0}{1}" -f $TaskPath, $TaskName)
    }
    else {
        Disable-ScheduledTask -InputObject $task | Out-Null
        Write-InfoLine ("Scheduled task disabled: {0}{1}" -f $TaskPath, $TaskName)
    }
}

function Backup-BcdSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($script:SeenBcdSettings.Contains($Name)) {
        return
    }

    $output = bcdedit /enum "{current}" 2>$null
    $exists = $false
    $value = $null

    foreach ($line in $output) {
        if ($line -match "^\s*$Name\s+(.+)$") {
            $exists = $true
            $value = $Matches[1].Trim()
            break
        }
    }

    $null = $script:SeenBcdSettings.Add($Name)
    $script:Backup.BcdSettings += [pscustomobject]@{
        Name   = $Name
        Exists = $exists
        Value  = $value
    }
}

function Restore-BcdSetting {
    param([Parameter(Mandatory = $true)]$Entry)

    if ($Entry.Exists) {
        bcdedit /set "{current}" $Entry.Name $Entry.Value | Out-Null
        Write-InfoLine ("BCD restored: {0} = {1}" -f $Entry.Name, $Entry.Value)
    }
    else {
        bcdedit /deletevalue "{current}" $Entry.Name 2>$null | Out-Null
        Write-InfoLine ("BCD removed: {0}" -f $Entry.Name)
    }
}

function Enable-UltimatePerformancePlan {
    $activeBefore = Get-ActivePowerSchemeGuid
    if (-not $script:Backup.ActivePowerScheme) {
        $script:Backup.ActivePowerScheme = $activeBefore
    }

    $targetGuid = $script:PowerPlanGuids.ULTIMATE_PERFORMANCE
    powercfg /SETACTIVE $targetGuid 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        $duplicateOutput = powercfg /DUPLICATESCHEME $script:PowerPlanGuids.ULTIMATE_PERFORMANCE 2>&1
        if ($duplicateOutput -match "([0-9A-Fa-f-]{36})") {
            $targetGuid = $Matches[1]
            powercfg /SETACTIVE $targetGuid 2>$null | Out-Null
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $targetGuid = $script:PowerPlanGuids.HIGH_PERFORMANCE
        powercfg /SETACTIVE $targetGuid 2>$null | Out-Null
    }

    if ($LASTEXITCODE -eq 0) {
        Write-InfoLine ("Active power plan set to {0}" -f $targetGuid)
    }
    else {
        Write-WarnLine "Could not activate Ultimate Performance or High Performance plan."
    }
}

function New-SystemRestorePointIfPossible {
    if ($SkipRestorePoint) {
        Write-WarnLine "Restore point creation skipped by parameter."
        return
    }

    try {
        Checkpoint-Computer -Description ("Win11 gaming tune " + (Get-Date -Format "yyyy-MM-dd HH:mm")) -RestorePointType MODIFY_SETTINGS | Out-Null
        Write-InfoLine "System restore point created."
    }
    catch {
        Write-WarnLine ("Restore point could not be created: {0}" -f $_.Exception.Message)
    }
}

function Apply-RegistryTweaks {
    Write-Section "Applying Registry Tweaks"

    Set-RegistryValueEx -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Type DWord -Value 0
    Set-RegistryValueEx -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Type DWord -Value 0
    Set-RegistryValueEx -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Type DWord -Value 0

    Set-RegistryValueEx -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Type DWord -Value 1
    Set-RegistryValueEx -Path "HKCU:\Software\Microsoft\GameBar" -Name "AllowAutoGameMode" -Type DWord -Value 1

    Set-RegistryValueEx -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Type String -Value "0"
    Set-RegistryValueEx -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Type String -Value "0"
    Set-RegistryValueEx -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Type String -Value "0"

    Set-RegistryValueEx -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Type DWord -Value 1
    Set-RegistryValueEx -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Type DWord -Value 10

    if ($DisableVbs) {
        Backup-BcdSetting -Name "hypervisorlaunchtype"
        Set-RegistryValueEx -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "EnableVirtualizationBasedSecurity" -Type DWord -Value 0
        Set-RegistryValueEx -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -Type DWord -Value 0
        bcdedit /set "{current}" hypervisorlaunchtype off | Out-Null
        Write-WarnLine "VBS/HVCI disabled. This can help performance, but it disables Hyper-V/WSL2/Sandbox style features."
    }
}

function Apply-Cs2CompetitiveTweaks {
    if (-not $Cs2Mode) {
        return
    }

    Write-Section "Applying CS2 Competitive Tweaks"

    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($battery) {
            Write-WarnLine "CS2 mode raises power draw and heat. It is mainly intended for desktops or plugged-in gaming laptops."
        }
    }
    catch {
        Write-WarnLine "Battery detection could not be completed. Continuing with CS2 power tweaks."
    }

    Set-RegistryValueEx -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "DisableUserPresenceQos" -Type DWord -Value 1
    Set-PowerSettingValueEx -Subgroup "SUB_USB" -Setting "USBSELECTIVE" -AcValue 0 -DcValue 0
    Set-PowerSettingValueEx -Subgroup "SUB_PCIEXPRESS" -Setting "ASPM" -AcValue 0 -DcValue 0
    Set-PowerSettingValueEx -Subgroup "SUB_PROCESSOR" -Setting "PERFEPP" -AcValue 0 -DcValue 0
    Set-PowerSettingValueEx -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMIN" -AcValue 100 -DcValue 100
    Set-PowerSettingValueEx -Subgroup "SUB_PROCESSOR" -Setting "PROCTHROTTLEMAX" -AcValue 100 -DcValue 100
    Set-PowerSettingValueEx -Subgroup "SUB_PROCESSOR" -Setting "CPMINCORES" -AcValue 100 -DcValue 100
    Set-PowerSettingValueEx -Subgroup "SUB_PROCESSOR" -Setting "CPMAXCORES" -AcValue 100 -DcValue 100
    Set-PowerSettingValueEx -Subgroup "SUB_PROCESSOR" -Setting "PERFBOOSTMODE" -AcValue 2 -DcValue 2

    Write-WarnLine "CS2 mode favors lower latency and steadier frametimes over heat, idle power draw, and battery life."
}

function Apply-ScheduledTaskTweaks {
    Write-Section "Disabling Background Scheduled Tasks"

    $safeTasks = @(
        @{ TaskPath = "\Microsoft\Windows\Maps\"; TaskName = "MapsUpdateTask" },
        @{ TaskPath = "\Microsoft\Windows\Maps\"; TaskName = "MapsToastTask" },
        @{ TaskPath = "\Microsoft\Windows\Feedback\Siuf\"; TaskName = "DmClient" },
        @{ TaskPath = "\Microsoft\Windows\Feedback\Siuf\"; TaskName = "DmClientOnScenarioDownload" }
    )

    $aggressiveTasks = @(
        @{ TaskPath = "\Microsoft\Windows\Application Experience\"; TaskName = "Microsoft Compatibility Appraiser" },
        @{ TaskPath = "\Microsoft\Windows\Application Experience\"; TaskName = "ProgramDataUpdater" },
        @{ TaskPath = "\Microsoft\Windows\Customer Experience Improvement Program\"; TaskName = "Consolidator" },
        @{ TaskPath = "\Microsoft\Windows\Customer Experience Improvement Program\"; TaskName = "KernelCeipTask" },
        @{ TaskPath = "\Microsoft\Windows\Customer Experience Improvement Program\"; TaskName = "UsbCeip" }
    )

    foreach ($task in $safeTasks) {
        Set-ScheduledTaskEnabledState -TaskPath $task.TaskPath -TaskName $task.TaskName -Enabled $false
    }

    if ($Profile -eq "Aggressive") {
        foreach ($task in $aggressiveTasks) {
            Set-ScheduledTaskEnabledState -TaskPath $task.TaskPath -TaskName $task.TaskName -Enabled $false
        }
    }
}

function Apply-ServiceTweaks {
    Write-Section "Reducing Services"

    $safeServicePlan = @(
        @{ Name = @("AJRouter"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("Fax"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("MapsBroker"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("lfsvc"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("PhoneSvc"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("RemoteRegistry"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("RetailDemo"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("WMPNetworkSvc"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("WbioSrvc"); Startup = "Manual"; Stop = $false },
        @{ Name = @("Wecsvc"); Startup = "Manual"; Stop = $false },
        @{ Name = @("WerSvc"); Startup = "Manual"; Stop = $false },
        @{ Name = @("TrkWks"); Startup = "Manual"; Stop = $false },
        @{ Name = @("SEMgrSvc"); Startup = "Manual"; Stop = $false },
        @{ Name = @("SCardSvr"); Startup = "Manual"; Stop = $false },
        @{ Name = @("ScDeviceEnum"); Startup = "Manual"; Stop = $false },
        @{ Name = @("FrameServer"); Startup = "Manual"; Stop = $false },
        @{ Name = @("stisvc"); Startup = "Manual"; Stop = $false }
    )

    $aggressiveServicePlan = @(
        @{ Name = @("DiagTrack"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("dmwappushservice"); Startup = "Disabled"; Stop = $true },
        @{ Name = @("DoSvc"); Startup = "Manual"; Stop = $false }
    )

    foreach ($item in $safeServicePlan) {
        Set-ServiceStartupEx -NamePattern $item.Name -StartupType $item.Startup -StopIfRunning:$item.Stop
    }

    if ($Profile -eq "Aggressive") {
        foreach ($item in $aggressiveServicePlan) {
            Set-ServiceStartupEx -NamePattern $item.Name -StartupType $item.Startup -StopIfRunning:$item.Stop
        }
    }

    if ($DisableRemoteDiscoveryServices) {
        Write-Section "Optional Bundle: Remote Discovery"
        Set-ServiceStartupEx -NamePattern @("SSDPSRV", "upnphost", "fdPHost", "FDResPub") -StartupType Disabled -StopIfRunning
        Set-ServiceStartupEx -NamePattern @("RemoteAccess", "RasAuto", "RasMan", "TapiSrv") -StartupType Disabled -StopIfRunning
    }

    if ($DisableBluetoothServices) {
        Write-Section "Optional Bundle: Bluetooth"
        Set-ServiceStartupEx -NamePattern @("bthserv", "BthAvctpSvc", "BTAGService") -StartupType Disabled -StopIfRunning
    }

    if ($DisablePrintServices) {
        Write-Section "Optional Bundle: Print"
        Set-ServiceStartupEx -NamePattern @("Spooler", "PrintNotify") -StartupType Disabled -StopIfRunning
    }

    if ($DisableTouchServices) {
        Write-Section "Optional Bundle: Touch and Pen"
        Set-ServiceStartupEx -NamePattern @("TabletInputService") -StartupType Disabled -StopIfRunning
    }

    if ($DisableXboxServices) {
        Write-Section "Optional Bundle: Xbox"
        Set-ServiceStartupEx -NamePattern @("XblAuthManager", "XblGameSave", "XboxNetApiSvc", "XboxGipSvc", "BcastDVRUserService*") -StartupType Disabled -StopIfRunning
    }

    if ($DisableSearchIndexing) {
        Write-Section "Optional Bundle: Search Indexing"
        Set-ServiceStartupEx -NamePattern @("WSearch") -StartupType Disabled -StopIfRunning
    }
}

function Restore-Optimizations {
    Write-Section "Restoring From Backup"
    $savedBackup = Get-BackupFileContent

    if ($savedBackup.Registry) {
        foreach ($entry in $savedBackup.Registry) {
            Restore-RegistryValue -Entry $entry
        }
    }

    if ($savedBackup.Services) {
        foreach ($entry in $savedBackup.Services) {
            Restore-ServiceConfiguration -Entry $entry
        }
    }

    if ($savedBackup.PowerSettings) {
        foreach ($entry in $savedBackup.PowerSettings) {
            Restore-PowerSettingConfiguration -Entry $entry
        }
    }

    if ($savedBackup.ScheduledTasks) {
        foreach ($entry in $savedBackup.ScheduledTasks) {
            Set-ScheduledTaskEnabledState -TaskPath $entry.TaskPath -TaskName $entry.TaskName -Enabled ([bool]$entry.Enabled)
        }
    }

    if ($savedBackup.BcdSettings) {
        foreach ($entry in $savedBackup.BcdSettings) {
            Restore-BcdSetting -Entry $entry
        }
    }

    if ($savedBackup.ActivePowerScheme) {
        powercfg /SETACTIVE $savedBackup.ActivePowerScheme | Out-Null
        Write-InfoLine ("Power plan restored: {0}" -f $savedBackup.ActivePowerScheme)
    }

    Write-WarnLine "Restore finished. Reboot is recommended."
}

function Invoke-Optimization {
    Write-Section "Creating Backup"
    $script:Backup.ActivePowerScheme = Get-ActivePowerSchemeGuid
    Save-BackupFile
    Write-InfoLine ("Backup saved to {0}" -f $BackupPath)
    New-SystemRestorePointIfPossible

    Enable-UltimatePerformancePlan
    Apply-RegistryTweaks
    Apply-Cs2CompetitiveTweaks
    Apply-ScheduledTaskTweaks
    Apply-ServiceTweaks

    Save-BackupFile

    Write-Section "Finished"
    Write-InfoLine "Optimization complete."
    Write-WarnLine "A reboot is recommended so all service and registry changes are fully applied."
    Write-WarnLine "This script will not magically recover 100 FPS if the main bottleneck is GPU driver, BIOS, chipset, memory, or in-game settings."
}

if ($env:OS -ne "Windows_NT") {
    throw "This script must be run on Windows."
}

if (-not (Test-IsAdministrator)) {
    throw "Run PowerShell as Administrator and execute the script again."
}

Write-Section "Windows 11 Gaming Tune"
Write-InfoLine ("Mode: {0}" -f $Mode)
Write-InfoLine ("Profile: {0}" -f $Profile)
Write-InfoLine ("Backup: {0}" -f $BackupPath)

switch ($Mode) {
    "Optimize" { Invoke-Optimization }
    "Restore" { Restore-Optimizations }
}
