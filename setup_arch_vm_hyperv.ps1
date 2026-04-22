param(
    [string]$VmName = "ArchDesktop",
    [string]$IsoPath = "archlinux-latest-x86_64.iso",
    [string]$OfficialIsoUrl = "https://fastly.mirror.pkgbuild.com/iso/2026.04.01/archlinux-2026.04.01-x86_64.iso",
    [string]$VmRoot = "C:\HyperV\VMs",
    [int]$CpuCount = 4,
    [int]$MemoryGB = 8,
    [int]$DiskGB = 80,
    [string]$SwitchName = "",
    [switch]$StartVm,
    [switch]$NoConsole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-IsoPath {
    param(
        [string]$Path,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = "archlinux-latest-x86_64.iso"
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        if (Test-Path -LiteralPath $Path) {
            return (Resolve-Path -LiteralPath $Path).Path
        }
    }
    else {
        $combined = Join-Path -Path $PSScriptRoot -ChildPath $Path
        if (Test-Path -LiteralPath $combined) {
            return (Resolve-Path -LiteralPath $combined).Path
        }
    }

    $candidatePaths = @(
        (Join-Path -Path $PSScriptRoot -ChildPath "archlinux-latest-x86_64.iso"),
        (Join-Path -Path $PSScriptRoot -ChildPath "out\archlinux-latest-x86_64.iso")
    )

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $searchRoots = @($PSScriptRoot, (Join-Path -Path $PSScriptRoot -ChildPath "out"))
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $latest = Get-ChildItem -LiteralPath $root -Filter "archlinux-*.iso" -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            return $latest.FullName
        }
    }

    if ($AllowMissing) {
        return $null
    }

    throw "ISO not found. Provide -IsoPath, build one with build_offline_autoinstall_iso.sh, or use -OfficialIsoUrl to download from a mirror."
}

function Get-IsoFileNameFromUrl {
    param([string]$Url)

    try {
        $uri = [System.Uri]$Url
    }
    catch {
        throw "Official ISO URL is invalid: '$Url'"
    }

    $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "Could not determine ISO filename from URL: '$Url'"
    }

    return $fileName
}

function Save-OfficialIso {
    param(
        [string]$Url,
        [string]$DestinationDir,
        [string]$AliasFileName = "archlinux-latest-x86_64.iso"
    )

    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    $fileName = Get-IsoFileNameFromUrl -Url $Url
    $downloadPath = Join-Path -Path $DestinationDir -ChildPath $fileName
    $aliasPath = Join-Path -Path $DestinationDir -ChildPath $AliasFileName
    $tempPath = "${downloadPath}.part"

    Write-Host "Downloading official Arch ISO from mirror..." -ForegroundColor Yellow
    Write-Host "URL : $Url"
    Write-Host "File: $downloadPath"

    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    Invoke-WebRequest -Uri $Url -OutFile $tempPath
    Move-Item -LiteralPath $tempPath -Destination $downloadPath -Force
    Copy-Item -LiteralPath $downloadPath -Destination $aliasPath -Force

    Write-Host "Downloaded official ISO to '$downloadPath'." -ForegroundColor Green
    Write-Host "Updated latest alias at '$aliasPath'." -ForegroundColor Green

    return $aliasPath
}

function Ensure-HyperV {
    try {
        Import-Module Hyper-V -ErrorAction Stop
    }
    catch {
        throw "Hyper-V PowerShell module is unavailable. Enable Hyper-V and reboot."
    }
}

function Get-OrCreateSwitch {
    param([string]$RequestedSwitchName)

    if ($RequestedSwitchName) {
        $requested = Get-VMSwitch -Name $RequestedSwitchName -ErrorAction SilentlyContinue
        if (-not $requested) {
            throw "Requested switch '$RequestedSwitchName' not found."
        }
        return $requested.Name
    }

    $defaultSwitch = Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue
    if ($defaultSwitch) {
        return $defaultSwitch.Name
    }

    $external = Get-VMSwitch | Where-Object { $_.SwitchType -eq "External" } | Select-Object -First 1
    if ($external) {
        return $external.Name
    }

    $adapter = Get-NetAdapter |
        Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface -eq $true } |
        Sort-Object -Property LinkSpeed -Descending |
        Select-Object -First 1

    if (-not $adapter) {
        throw "No active physical network adapter found for external switch creation."
    }

    $newSwitchName = "ExternalSwitch"
    New-VMSwitch -Name $newSwitchName -NetAdapterName $adapter.Name -AllowManagementOS $true | Out-Null
    return $newSwitchName
}

function Open-VmConsole {
    param([string]$TargetVmName)

    $vmConnectPath = Join-Path -Path $env:WINDIR -ChildPath "System32\vmconnect.exe"
    if (-not (Test-Path -LiteralPath $vmConnectPath)) {
        Write-Warning "VMConnect not found at '$vmConnectPath'. Open Hyper-V Manager and connect to '$TargetVmName'."
        return
    }

    Start-Process -FilePath $vmConnectPath -ArgumentList "localhost", $TargetVmName | Out-Null
    Write-Host "Opened VM console for '$TargetVmName'." -ForegroundColor Green
}

if (-not (Test-IsAdmin)) {
    throw "Run this script in an elevated PowerShell session (Run as Administrator)."
}

Ensure-HyperV

$resolvedIso = Resolve-IsoPath -Path $IsoPath -AllowMissing
if (-not $resolvedIso) {
    $downloadedAlias = Save-OfficialIso -Url $OfficialIsoUrl -DestinationDir $PSScriptRoot
    $resolvedIso = Resolve-IsoPath -Path $downloadedAlias
}

$switchToUse = Get-OrCreateSwitch -RequestedSwitchName $SwitchName

if (-not (Test-Path -LiteralPath $VmRoot)) {
    New-Item -ItemType Directory -Path $VmRoot -Force | Out-Null
}

$vmFolder = Join-Path -Path $VmRoot -ChildPath $VmName
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
$vmCreated = $false

if (-not $vm) {
    if (Test-Path -LiteralPath $vmFolder) {
        Write-Host "Cleaning up leftover files from previous incomplete creation..." -ForegroundColor Yellow
        Remove-Item -LiteralPath $vmFolder -Recurse -Force | Out-Null
    }

    New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null

    $vhdPath = Join-Path -Path $vmFolder -ChildPath "$VmName.vhdx"
    New-VHD -Path $vhdPath -SizeBytes ($DiskGB * 1GB) -Dynamic | Out-Null

    New-VM `
        -Name $VmName `
        -Generation 2 `
        -MemoryStartupBytes ($MemoryGB * 1GB) `
        -VHDPath $vhdPath `
        -Path $vmFolder `
        -SwitchName $switchToUse | Out-Null

    Set-VMProcessor -VMName $VmName -Count $CpuCount
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
    Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $vmCreated = $true
}
else {
    Write-Host "VM '$VmName' already exists. Reusing existing VM." -ForegroundColor Yellow
}

$wasRunning = $false
$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.State -eq "Running") {
    $wasRunning = $true
    Write-Host "Stopping running VM so firmware settings can be updated..." -ForegroundColor Yellow
    Stop-VM -Name $VmName -TurnOff -Force | Out-Null
}

$dvd = Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dvd) {
    if ($dvd.Path -ne $resolvedIso) {
        Set-VMDvdDrive -VMName $VmName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $resolvedIso
        $dvd = Get-VMDvdDrive -VMName $VmName -ErrorAction Stop | Select-Object -First 1
    }
}
else {
    $dvd = Add-VMDvdDrive -VMName $VmName -Path $resolvedIso
}

Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd

if ($vmCreated) {
    Write-Host "VM created successfully." -ForegroundColor Green
}
else {
    Write-Host "VM configuration refreshed." -ForegroundColor Green
}
Write-Host "Name: $VmName"
Write-Host "ISO : $resolvedIso"
Write-Host "CPU : $CpuCount"
Write-Host "RAM : $($MemoryGB)GB"
Write-Host "Disk: $($DiskGB)GB"
Write-Host "Switch: $switchToUse"

if ($StartVm) {
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.State -eq "Running") {
        Write-Host "VM is already running." -ForegroundColor Green
    }
    else {
        Start-VM -Name $VmName | Out-Null
        Write-Host "VM started." -ForegroundColor Green
    }
    if (-not $NoConsole) {
        Open-VmConsole -TargetVmName $VmName
    }
    else {
        Write-Host "Console launch skipped. Open Hyper-V Manager and connect to '$VmName' to begin Arch install."
    }
}
elseif ($wasRunning) {
    Write-Host "VM was stopped for reconfiguration and is currently off." -ForegroundColor Yellow
    Write-Host "Run Start-VM -Name '$VmName' when ready."
}
else {
    Write-Host "Run Start-VM -Name '$VmName' when ready."
}
