<#
.SYNOPSIS
    Führt eine Auswahl von Testfällen aus - ein Copilot-Session pro Spec.

.DESCRIPTION
    Verteilt die Specs deterministisch auf parallele Pipeline-Jobs (Slicing) und
    ruft für jeden Testfall Invoke-LlmTest.ps1 auf.

    Exit-Code 1, wenn mindestens ein Testfall fehlgeschlagen ist. Blockierte Tests
    (Umgebungsproblem) zählen nicht als Fehlschlag.

.EXAMPLE
    ./platform/tools/Invoke-TestSuite.ps1 -OutDir artifacts/e2e -Tag smoke

.EXAMPLE
    ./platform/tools/Invoke-TestSuite.ps1 -OutDir artifacts/e2e -Slice 2 -SliceCount 4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutDir,
    [string]   $SpecDir    = 'tests/specs',
    [string]   $Suite,
    [string[]] $Tag,
    [string[]] $Id,
    [int]      $Slice      = 1,
    [int]      $SliceCount = 1,
    [switch]   $ContinueOnFailure
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Slice -lt 1 -or $Slice -gt $SliceCount) {
    throw "-Slice muss zwischen 1 und $SliceCount liegen (war $Slice)."
}

# --------------------------------------------------------------------------
# Auswahl bilden. Sortierung nach Dateiname = stabile Verteilung über die Jobs.
# --------------------------------------------------------------------------
$specFiles = Get-ChildItem -Path $SpecDir -Filter '*.md' -Recurse -File |
             Sort-Object FullName

if (-not $specFiles) { throw "Keine Specs unter $SpecDir gefunden." }

# Front Matter nur zum Filtern anlesen - die eigentliche Prüfung macht Invoke-LlmTest.
$specs = foreach ($file in $specFiles) {
    $head = (Get-Content -LiteralPath $file.FullName -TotalCount 15) -join "`n"
    [pscustomobject]@{
        Path  = $file.FullName
        Id    = if ($head -match '(?m)^id:\s*(.+)$')    { $Matches[1].Trim() } else { $file.BaseName }
        Suite = if ($head -match '(?m)^suite:\s*(.+)$') { $Matches[1].Trim() } else { 'E2E' }
        Tags  = if ($head -match '(?m)^tags:\s*\[(.*)\]$') {
                    @($Matches[1] -split ',' | ForEach-Object { $_.Trim(' ', '"', "'") } | Where-Object { $_ })
                } else { @() }
    }
}

# Doppelte IDs machen die Testhistorie in Azure DevOps unbrauchbar.
$duplicates = $specs | Group-Object Id | Where-Object Count -gt 1
if ($duplicates) {
    throw "Mehrfach vergebene Test-IDs: $($duplicates.Name -join ', ')"
}

if ($Suite) { $specs = $specs | Where-Object Suite -eq $Suite }
if ($Tag)   { $specs = $specs | Where-Object { $_.Tags | Where-Object { $_ -in $Tag } } }
if ($Id)    { $specs = $specs | Where-Object Id -in $Id }

if ($SliceCount -gt 1) {
    # Round Robin über die sortierte Liste: Job N bekommt immer dieselben Specs.
    $index = 0
    $specs = $specs | Where-Object { (($index++) % $SliceCount) -eq ($Slice - 1) }
}

$specs = @($specs)
if ($specs.Count -eq 0) {
    Write-Host 'Keine Testfälle in dieser Auswahl - nichts zu tun.'
    exit 0
}

# --------------------------------------------------------------------------

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Write-Host "$($specs.Count) Testfälle (Slice $Slice/$SliceCount), Basis-URL $($env:BASE_URL)"
Write-Host ''

$results = foreach ($spec in $specs) {
    & "$PSScriptRoot/Invoke-LlmTest.ps1" -SpecPath $spec.Path -OutDir $OutDir
}

$results = @($results | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Outcome'] })
$failed  = @($results | Where-Object Outcome -eq 'failed')
$blocked = @($results | Where-Object Outcome -eq 'blocked')
$passed  = $results.Count - $failed.Count - $blocked.Count

Write-Host ''
Write-Host "Ergebnis: $passed bestanden, $($failed.Count) fehlgeschlagen, $($blocked.Count) blockiert."

# Fehler direkt im Pipeline-Protokoll sichtbar machen.
if ($env:TF_BUILD -eq 'True') {
    foreach ($r in $failed) {
        Write-Host "##vso[task.logissue type=error]$($r.Id): $($r.Summary -replace "`r?`n", ' ')"
    }
    foreach ($r in $blocked) {
        Write-Host "##vso[task.logissue type=warning]$($r.Id) blockiert: $($r.Summary -replace "`r?`n", ' ')"
    }
    # Blockiert ist kein Fehlschlag, aber auch kein Erfolg: Schritt orange markieren.
    if ($blocked.Count -gt 0 -and $failed.Count -eq 0) {
        Write-Host '##vso[task.complete result=SucceededWithIssues;]Testfälle blockiert'
    }
}

if ($ContinueOnFailure) { exit 0 }
exit ($failed.Count -gt 0 ? 1 : 0)
