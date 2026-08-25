#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$Plan,
    [switch]$Apply,
    [switch]$ConfirmReviewed
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\machine.psd1' }
$coreModule = Join-Path $PSScriptRoot 'lib\PcSetup.Core.psm1'
$recoveryModule = Join-Path $PSScriptRoot 'lib\PcSetup.Recovery.psm1'
Import-Module $coreModule -Force
Import-Module $recoveryModule -Force

$mode = Get-PcSetupExecutionMode -Plan:$Plan -Apply:$Apply
$configuration = Import-PcSetupConfiguration -Path $Config
$debloat = $configuration.Debloat
$summary = [pscustomobject]@{
    Step       = 'Debloat'
    Mode       = $mode
    Enabled    = [bool]$debloat.Enabled
    Repository = [string]$debloat.Repository
    Release    = [string]$debloat.Release
    Preset     = [string]$debloat.Preset
    Action     = if ($debloat.Enabled) { "$($debloat.Preset):$($debloat.AppRemovalTarget)" } else { 'None' }
}

if (-not $debloat.Enabled) {
    Write-Host '[IGNORADO] Debloat desabilitado neste perfil. O Windows permanece com o comportamento original.'
    return $summary
}
if ($mode -eq 'Plan') {
    Write-Host "[PLANO] Baixar $($debloat.Repository) $($debloat.Release), validar SHA-256 e executar $($debloat.Preset) para $($debloat.AppRemovalTarget). RemoveGamingApps=$([bool]$debloat.RemoveGamingApps)."
    return $summary
}
if (-not $ConfirmReviewed) { throw 'Debloat exige -ConfirmReviewed depois da leitura de docs\DEBLOAT.md.' }
if ([string]::IsNullOrWhiteSpace([string]$debloat.ArchiveSha256) -or [string]$debloat.ArchiveSha256 -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'Defina Debloat.ArchiveSha256 com o SHA-256 revisado da release antes de habilitar o debloat.'
}

Assert-PcSetupAdministrator
$null = Enter-PcSetupProtectedScript -EntryPoint $MyInvocation.MyCommand.Name
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Execute o debloat diretamente no Windows PowerShell 5.1, nao no PowerShell 7.' }

$workRoot = Join-Path $env:TEMP ("pc-setup-win11debloat-" + [guid]::NewGuid().ToString('N'))
$zipPath = "$workRoot.zip"
$url = "https://github.com/$($debloat.Repository)/archive/refs/tags/$($debloat.Release).zip"
try {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actualHash -ne ([string]$debloat.ArchiveSha256).ToUpperInvariant()) { throw 'O SHA-256 do arquivo de debloat baixado diverge do valor revisado.' }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $workRoot -Force
    $scriptFile = Get-ChildItem -LiteralPath $workRoot -Recurse -Filter 'Win11Debloat.ps1' -File | Select-Object -First 1
    if (-not $scriptFile) { throw 'Win11Debloat.ps1 nao foi encontrado no arquivo validado.' }
    Get-ChildItem -LiteralPath $scriptFile.Directory.FullName -Recurse -File | Unblock-File

    $invocationParameters = @{
        RunDefaults      = $true
        AppRemovalTarget = [string]$debloat.AppRemovalTarget
    }
    if ($debloat.Silent) { $invocationParameters.Silent = $true }
    if ($debloat.RemoveGamingApps) { $invocationParameters.RemoveGamingApps = $true }
    Write-Host "[APLICAR] Win11Debloat $($debloat.Preset), alvo $($debloat.AppRemovalTarget), RemoveGamingApps=$([bool]$debloat.RemoveGamingApps)." -ForegroundColor Yellow
    & $scriptFile.FullName @invocationParameters
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Win11Debloat terminou com codigo $LASTEXITCODE." }
}
finally {
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
}

[pscustomobject]@{ Step = 'Debloat'; Mode = $mode; Enabled = $true; Repository = $debloat.Repository; Release = $debloat.Release; Action = 'Completed' }
