<#
.SYNOPSIS
    Führt einen einzelnen LLM-gesteuerten E2E-Test aus: eine Copilot-Session pro
    Testfall, Ergebnis als verdict.json.

.DESCRIPTION
    Der Exit-Code der Session sagt nur, ob der Prozess durchgelaufen ist, nicht ob
    der Test fachlich bestanden wurde. Maßgeblich ist allein die Urteilsdatei.

    Grundregel: Ein fehlendes Urteil ist ein Fehlschlag. Nie "passed" annehmen.

.EXAMPLE
    ./platform/tools/Invoke-LlmTest.ps1 -SpecPath tests/specs/SHOP-001.md -OutDir artifacts/e2e

.EXAMPLE
    # Lokal: sichtbarer Browser, interaktive Copilot-Session, ein Versuch
    ./platform/tools/Invoke-LlmTest.ps1 -SpecPath tests/specs/SHOP-001.md -OutDir artifacts/local -Interactive
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SpecPath,
    [Parameter(Mandatory)][string] $OutDir,
    [int]    $MaxAttempts    = 0,     # 0 = Wert aus dem Front Matter der Spec
    [string] $PromptTemplate = './tests/prompt.agent.template.md',
    [string] $McpConfig      = './platform/.copilot',
    [string] $AgentRoot      = './platform',   # enthält .github/agents; wird per --add-dir geladen
    [string] $Agent          = 'e2e-runner',   # leer = ohne Custom Agent (altes prompt.template.md)
    [switch] $Headed,                          # Browser sichtbar (ohne --headless)
    [switch] $Interactive                      # interaktive Session, impliziert -Headed und einen Versuch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/E2E.Common.ps1"

# --------------------------------------------------------------------------

$spec = Read-SpecFile -Path $SpecPath
$attempts = if ($Interactive) { 1 } elseif ($MaxAttempts -gt 0) { $MaxAttempts } else { $spec.maxAttempts }
if ($Interactive) { $Headed = $true }
$agentRootPath = (Resolve-Path -LiteralPath $AgentRoot).Path

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$verdict = $null

# Zugangsdaten gehen nur an Playwright MCP (--secrets): Der Agent tippt den Namen,
# MCP setzt den Wert ein.
$secretsFile = New-E2ESecretsFile
$env:E2E_SECRETS_FILE = $secretsFile

try {
for ($attempt = 1; $attempt -le $attempts; $attempt++) {

    $runDir      = Join-Path $OutDir "$($spec.id)/attempt-$attempt"
    $evidenceDir = Join-Path $runDir 'evidence'
    $logDir      = Join-Path $runDir 'agent-log'
    New-Item -ItemType Directory -Path $evidenceDir, $logDir -Force | Out-Null

    $resultFile = Join-Path $runDir 'verdict.json'
    $promptFile = Join-Path $runDir 'prompt.md'
    $stdoutFile = Join-Path $runDir 'stdout.log'
    $stderrFile = Join-Path $runDir 'stderr.log'

    $prompt = Expand-PromptTemplate -TemplatePath $PromptTemplate -Spec $spec `
                -ResultFile $resultFile -EvidenceDir $evidenceDir -BaseUrl $env:BASE_URL

    Set-Content -LiteralPath $promptFile -Value $prompt -Encoding utf8

    Write-Host "  $($spec.id): Session startet (Versuch $attempt/$attempts, Timeout $($spec.timeoutSec)s)"

    # Playwright MCP schreibt Traces und Screenshots hierhin (siehe mcp-config.json).
    $env:E2E_EVIDENCE_DIR = $evidenceDir

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut  = $false

    $mcpConfigFile = (Resolve-Path -LiteralPath (
        Join-Path $McpConfig 'mcp-config.json'
    )).Path

    if ($Headed) {
        $headedConfig = Join-Path $runDir 'mcp-config.headed.json'
        New-HeadedMcpConfig -Source $mcpConfigFile -Destination $headedConfig
        $mcpConfigFile = $headedConfig
    }

    $copilotArgs = @(
        '--allow-all-tools'
        '--additional-mcp-config', "@$mcpConfigFile"
        '--add-dir', $agentRootPath
        '--add-dir', $evidenceDir
        '--add-dir', $runDir
        '--log-dir', $logDir,
        '--secret-env-vars=E2E_USER,E2E_PASSWORD'
        '--no-color'
    )
    if ($Agent) { $copilotArgs += '--agent', $Agent }

    if ($Interactive) {
        # Interaktiv: kein Pipe, damit die TUI ein Terminal hat. Prompt wird sofort ausgeführt.
        & copilot @copilotArgs --interactive $prompt
    }
    else {
        & copilot @copilotArgs --prompt $prompt --no-color 2>&1 |
            Tee-Object -FilePath $stdoutFile |
            Out-Host
    }

    $exitCode = $LASTEXITCODE

    $stopwatch.Stop()

    # ---- Urteil lesen. Im Zweifel: failed. ----
    if ($timedOut) {
        $verdict = @{ id = $spec.id; outcome = 'failed'
                      summary = "Timeout nach $($spec.timeoutSec)s - Session abgebrochen."
                      verdictSource = 'runner' }
    }
    elseif (-not (Test-Path -LiteralPath $resultFile)) {
        $verdict = @{ id = $spec.id; outcome = 'failed'
                      summary = "Agent hat kein Urteil geschrieben (Exit-Code $exitCode)."
                      verdictSource = 'runner' }
    }
    else {
        try {
            $raw = Get-Content -LiteralPath $resultFile -Raw

            # Toleriert Vor-/Nachgeplapper des Modells um das JSON herum.
            $start = $raw.IndexOf('{'); $end = $raw.LastIndexOf('}')
            if ($start -lt 0 -or $end -le $start) { throw 'Kein JSON-Objekt gefunden.' }

            $parsed = $raw.Substring($start, $end - $start + 1) | ConvertFrom-Json -AsHashtable
            $parsed.verdictSource = 'agent'

            # Der Agent darf sich nicht selbst umbenennen.
            if ($parsed.id -ne $spec.id) {
                throw "Urteil trug fremde ID '$($parsed.id)' statt '$($spec.id)'."
            }
            # Widersprüchliches Urteil ist kein bestandener Test.
            if ($parsed.outcome -eq 'passed' -and $parsed.failedCriteria.Count -gt 0) {
                throw "Urteil widersprüchlich: 'passed' mit offenen Kriterien."
            }

            $verdict = $parsed
        }
        catch {
            $verdict = @{ id = $spec.id; outcome = 'failed'
                          summary = "Urteil nicht verwertbar: $($_.Exception.Message)"
                          verdictSource = 'runner' }
        }
    }

    # ---- Kontext ergänzen, den nur der Runner kennt ----
    $verdict.name        = $spec.name
    $verdict.suite       = $spec.suite
    $verdict.tags        = $spec.tags
    $verdict.attempt     = $attempt
    $verdict.maxAttempts = $attempts
    $verdict.wallMs      = $stopwatch.ElapsedMilliseconds
    $verdict.timedOut    = $timedOut
    $verdict.exitCode    = $exitCode
    $verdict.artifactDir = (Resolve-Path -LiteralPath $runDir).Path
    $verdict.sourcePath  = $spec.sourcePath
    if (-not $verdict.ContainsKey('toolCalls')) { $verdict.toolCalls = 0 }

    # Belege nachtragen, falls der Agent sie nicht gemeldet hat.
    if (-not $verdict.ContainsKey('evidence') -or $verdict.evidence.Count -eq 0) {
        $verdict.evidence = @(Get-ChildItem -LiteralPath $evidenceDir -Recurse -File -ErrorAction SilentlyContinue |
                              Select-Object -First 25 |
                              ForEach-Object { [IO.Path]::GetRelativePath($runDir, $_.FullName) })
    }

    Write-Host ("  {0}: {1} ({2:N0}s, {3} Tool-Calls, Quelle={4})" -f `
        $spec.id, $verdict.outcome.ToUpper(), $stopwatch.Elapsed.TotalSeconds,
        $verdict.toolCalls, $verdict.verdictSource)

    if ($verdict.outcome -ne 'failed') { break }

    if ($attempt -lt $attempts) {
        Write-Host "  $($spec.id): Versuch $attempt fehlgeschlagen, wiederhole ..."
    }
}
}
finally {
    Remove-Item -LiteralPath $secretsFile -Force -ErrorAction SilentlyContinue
}

$finalPath = Join-Path $OutDir "$($spec.id).final.json"
$verdict | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $finalPath -Encoding utf8

# Rückgabe für den Aufrufer (Invoke-TestSuite.ps1)
[pscustomobject]@{
    Id      = $spec.id
    Outcome = $verdict.outcome
    Summary = $verdict.summary
    Path    = $finalPath
}
