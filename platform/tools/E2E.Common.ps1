# Gemeinsame Funktionen für Invoke-LlmTest.ps1 (Pipeline) und die lokalen Skripte im Repo-Root.
# Per Dot-Sourcing einbinden: . "$PSScriptRoot/E2E.Common.ps1"

# Spec einlesen: YAML-Front-Matter (nur die benötigte Teilmenge) + Markdown-Rumpf
function Read-SpecFile {
    param([Parameter(Mandatory)][string] $Path)

    $text = (Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n"

    if ($text -notmatch '(?s)^---\n(.*?)\n---\n(.*)$') {
        throw "$Path`: Front-Matter-Block (---) fehlt oder ist nicht abgeschlossen."
    }

    $frontMatter = $Matches[1]
    $body        = $Matches[2].Trim()

    $spec = @{
        timeoutSec  = 600
        maxAttempts = 2
        suite       = 'E2E'
        tags        = @()
    }

    foreach ($line in $frontMatter -split "`n") {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        $colon = $trimmed.IndexOf(':')
        if ($colon -lt 1) { throw "$Path`: Front-Matter-Zeile ohne ':' -> '$trimmed'" }

        $key   = $trimmed.Substring(0, $colon).Trim()
        $value = $trimmed.Substring($colon + 1).Trim().Trim('"', "'")

        switch ($key) {
            'timeoutSec'  { $spec[$key] = [int] $value }
            'maxAttempts' { $spec[$key] = [int] $value }
            'tags'        { $spec[$key] = @($value.Trim('[', ']') -split ',' |
                                            ForEach-Object { $_.Trim(' ', '"', "'") } |
                                            Where-Object { $_ }) }
            default       { $spec[$key] = $value }
        }
    }

    foreach ($required in 'id', 'name') {
        if (-not $spec.ContainsKey($required)) { throw "$Path`: Front Matter '$required' fehlt." }
    }

    if ($body -notmatch 'Erfolgskriterien') {
        throw "$($spec.id): Abschnitt 'Erfolgskriterien' fehlt. Ohne prüfbare Kriterien kann der Agent nicht urteilen."
    }

    $spec.body       = $body
    $spec.sourcePath = (Resolve-Path -LiteralPath $Path).Path
    return $spec
}

function Expand-PromptTemplate {
    param(
        [Parameter(Mandatory)][string] $TemplatePath,
        [Parameter(Mandatory)][hashtable] $Spec,
        [Parameter(Mandatory)][string] $ResultFile,
        [Parameter(Mandatory)][string] $EvidenceDir,
        [string] $BaseUrl
    )
    (Get-Content -LiteralPath $TemplatePath -Raw).
        Replace('{{RESULT_FILE}}',  $ResultFile).
        Replace('{{EVIDENCE_DIR}}', $EvidenceDir).
        Replace('{{ID}}',           $Spec.id).
        Replace('{{BASE_URL}}',     ($BaseUrl ? $BaseUrl : '(nicht gesetzt)')).
        Replace('{{SPEC_BODY}}',    $Spec.body)
}

# Schreibt E2E_USER/E2E_PASSWORD als dotenv-Datei für `playwright-mcp --secrets` und gibt den Pfad zurück.
# Bewusst im Temp-Verzeichnis: Ergebnisordner werden als Artefakt veröffentlicht.
function New-E2ESecretsFile {
    $file = Join-Path ([IO.Path]::GetTempPath()) "e2e-secrets-$([guid]::NewGuid()).env"
    $lines = foreach ($name in 'E2E_USER', 'E2E_PASSWORD') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not $value) { continue }
        # dotenv kennt keine Escapes: ein Anführungszeichen wählen, das im Wert nicht vorkommt.
        $quote = "'", '"', '`' | Where-Object { -not $value.Contains($_) } | Select-Object -First 1
        if (-not $quote) { throw "$name lässt sich nicht im dotenv-Format schreiben." }
        "$name=$quote$value$quote"
    }
    Set-Content -LiteralPath $file -Value $lines -Encoding utf8NoBOM
    return $file
}

# Kopiert die MCP-Konfiguration ohne --headless, damit der Browser sichtbar ist.
function New-HeadedMcpConfig {
    param([Parameter(Mandatory)][string] $Source, [Parameter(Mandatory)][string] $Destination)
    $cfg = Get-Content -LiteralPath $Source -Raw | ConvertFrom-Json
    $cfg.mcpServers.playwright.args = @($cfg.mcpServers.playwright.args | Where-Object { $_ -ne '--headless' })
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Destination -Encoding utf8
}
