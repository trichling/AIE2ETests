<#
.SYNOPSIS
    Startet eine interaktive Copilot-Session mit dem e2e-runner-Agenten und sichtbarem Playwright-Browser,
    um Specs effizient zu entwickeln. Gleiche Bausteine wie in der Pipeline (Agent, MCP-Konfiguration, --secrets).

.DESCRIPTION
    Terminal 1:  ./Start-E2ESession.ps1
    Terminal 2:  ./New-E2EPrompt.ps1 -SpecPath tests/specs/SHOP-001.md   (kopiert den Prompt in die Zwischenablage)
    Danach den Prompt in Terminal 1 einfügen.

    Zugangsdaten: E2E_USER und E2E_PASSWORD aus der Umgebung, sonst werden sie abgefragt.
    Der Agent kennt die Werte nicht; er tippt die Namen, Playwright MCP setzt die Werte ein.

.EXAMPLE
    ./Start-E2ESession.ps1
    ./Start-E2ESession.ps1 -BaseUrl https://mein-qa.apetito.de
#>
[CmdletBinding()]
param(
    [string] $BaseUrl = ($env:BASE_URL ? $env:BASE_URL : 'https://mein.apetito.de'),
    [string] $OutDir  = 'artifacts/dev',
    [string] $Agent   = 'e2e-runner'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location $PSScriptRoot

. "$PSScriptRoot/platform/tools/E2E.Common.ps1"

if (-not $env:E2E_USER) { $env:E2E_USER = Read-Host 'E2E_USER' }
if (-not $env:E2E_PASSWORD) {
    $secure = Read-Host 'E2E_PASSWORD' -AsSecureString
    $env:E2E_PASSWORD = [Net.NetworkCredential]::new('', $secure).Password
}

$sessionDir  = Join-Path $OutDir (Get-Date -Format 'yyyyMMdd-HHmmss')
$evidenceDir = Join-Path $sessionDir 'evidence'
$logDir      = Join-Path $sessionDir 'agent-log'
New-Item -ItemType Directory -Path $evidenceDir, $logDir -Force | Out-Null
$sessionDir  = (Resolve-Path $sessionDir).Path
$evidenceDir = (Resolve-Path $evidenceDir).Path

# New-E2EPrompt.ps1 liest hier, wohin die laufende Session Belege und Urteil schreibt.
@{ sessionDir = $sessionDir; evidenceDir = $evidenceDir; baseUrl = $BaseUrl } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutDir 'current.json') -Encoding utf8

$headedConfig = Join-Path $sessionDir 'mcp-config.headed.json'
New-HeadedMcpConfig -Source (Resolve-Path './platform/.copilot/mcp-config.json').Path -Destination $headedConfig

$secretsFile = New-E2ESecretsFile
$env:E2E_SECRETS_FILE = $secretsFile
$env:E2E_EVIDENCE_DIR = $evidenceDir
$env:BASE_URL         = $BaseUrl

try {
    Write-Host "Session:  $sessionDir"
    Write-Host "Basis-URL: $BaseUrl"
    Write-Host 'Prompt für eine Spec erzeugen:  ./New-E2EPrompt.ps1 -SpecPath tests/specs/<SPEC>.md'
    Write-Host ''

    $copilotArgs = @(
        '--allow-all-tools'
        '--additional-mcp-config', "@$headedConfig"
        '--add-dir', (Resolve-Path './platform').Path
        '--add-dir', $sessionDir
        '--log-dir', $logDir
        '--secret-env-vars=E2E_USER,E2E_PASSWORD'
        '--agent', $Agent
    )
    & copilot @copilotArgs
}
finally {
    Remove-Item -LiteralPath $secretsFile -Force -ErrorAction SilentlyContinue
}
