<#
.SYNOPSIS
    Baut aus einer Spec den fertigen Prompt für den e2e-runner-Agenten und kopiert ihn in die Zwischenablage.

.DESCRIPTION
    Nutzt dieselbe Vorlage und dieselbe Platzhalter-Ersetzung wie die Pipeline (Invoke-LlmTest.ps1).
    Urteilsdatei und Belege-Ordner stammen aus der zuletzt gestarteten Session (Start-E2ESession.ps1).

.EXAMPLE
    ./New-E2EPrompt.ps1 -SpecPath tests/specs/SHOP-001.md
    ./New-E2EPrompt.ps1 tests/specs/SHOP-001.md -NoClipboard
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string] $SpecPath,
    [string] $OutDir   = 'artifacts/dev',
    [string] $Template = (Join-Path $PSScriptRoot 'tests/prompt.agent.template.md'),
    [switch] $NoClipboard
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/platform/tools/E2E.Common.ps1"

$sessionFile = Join-Path ([IO.Path]::GetFullPath($OutDir, $PSScriptRoot)) 'current.json'
if (-not (Test-Path -LiteralPath $sessionFile)) {
    throw "Keine Session gefunden ($sessionFile). Zuerst ./Start-E2ESession.ps1 in einem anderen Terminal starten."
}
$session = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json

$spec       = Read-SpecFile -Path $SpecPath
$resultFile = Join-Path $session.sessionDir "verdict-$($spec.id).json"
$prompt     = Expand-PromptTemplate -TemplatePath $Template -Spec $spec `
                -ResultFile $resultFile -EvidenceDir $session.evidenceDir -BaseUrl $session.baseUrl

$promptFile = Join-Path $session.sessionDir "prompt-$($spec.id).md"
Set-Content -LiteralPath $promptFile -Value $prompt -Encoding utf8

if (-not $NoClipboard) { Set-Clipboard -Value $prompt }

Write-Host $prompt
Write-Host ''
Write-Host "--- $($spec.id): $($spec.name)"
Write-Host "Prompt:  $promptFile$($NoClipboard ? '' : '  (in der Zwischenablage)')"
Write-Host "Urteil:  $resultFile"
