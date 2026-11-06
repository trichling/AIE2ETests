# LLM-gesteuerte E2E-Tests — einfacher Aufbau

Alles in einem Repo, neben dem Funktionscode. Fünf bewegliche Teile:

```
tests/specs/*.md            Testfälle in natürlicher Sprache
tests/prompt.agent.template.md  Auftrag je Testfall (ID, Basis-URL, Pfade, Spec)
.github/agents/e2e-runner.agent.md  Verhalten des Agenten und Urteilsformat
.copilot/mcp-config.json    Playwright MCP, headless und isoliert
tools/Invoke-LlmTest.ps1    Eine Spec -> eine Copilot-Session -> ein Urteil
tools/Invoke-TestSuite.ps1  Auswahl, Slicing, Aufruf je Testfall
tools/junit.cs              Urteile -> JUnit-XML (einzelne Datei, dotnet run)
azure-pipelines.yml         Ruft alles auf und veröffentlicht die Ergebnisse
```

Voraussetzungen: PowerShell 7, .NET 10 SDK, Node (für `npx`), `@github/copilot`.

Die Pipeline installiert Chromium mit der Playwright-Version, von der
`@playwright/mcp@latest` abhängt (automatisch ermittelt), und startet den
MCP-Server als Smoke-Test. Hintergrund: [docs/adr/0001](../docs/adr/0001-playwright-mcp-chromium-und-os-image.md).

## Lokal ausführen

```powershell
$env:BASE_URL = 'https://shop-test.apetito.de'
$env:GITHUB_TOKEN = '...'

# Neue Spec entwickeln, zwei Terminals im Repo-Root:
#   Terminal 1: interaktive Copilot-Session mit e2e-runner und sichtbarem Browser
./Start-E2ESession.ps1
#   Terminal 2: Prompt aus der Spec bauen (landet in der Zwischenablage), dann in Terminal 1 einfügen
./New-E2EPrompt.ps1 tests/specs/SHOP-001.md

# Dasselbe in einem Schritt, mit festem Prompt: interaktive Session, ein Versuch.
./platform/tools/Invoke-LlmTest.ps1 -SpecPath tests/specs/SHOP-001.md -OutDir artifacts/local -Interactive

# Wie Pipeline, aber mit sichtbarem Browser
./platform/tools/Invoke-LlmTest.ps1 -SpecPath tests/specs/SHOP-001.md -OutDir artifacts/local -Headed

# Ein einzelner Testfall
./platform/tools/Invoke-LlmTest.ps1 -SpecPath tests/specs/SHOP-001.md -OutDir artifacts/e2e

# Die ganze Smoke-Auswahl
./platform/tools/Invoke-TestSuite.ps1 -OutDir artifacts/e2e -Tag smoke

# JUnit erzeugen
dotnet run platform/tools/junit.cs -- --in artifacts/e2e
```

## Der Vertrag

Das ist der Kern, nicht die Skripte. Der Exit-Code der Copilot-Session sagt nur, ob
der Prozess durchgelaufen ist — nicht, ob der Test fachlich bestanden wurde. Ein
Agent kann sauber mit 0 beenden und dabei berichten, dass die Anwendung kaputt ist.
Oder mit 0 beenden, ohne je einen Browser geöffnet zu haben.

Deshalb schreibt der Agent sein Urteil in eine Datei, und der Runner traut
ausschließlich dieser Datei:

```json
{
  "id": "SHOP-001",
  "outcome": "passed | failed | blocked",
  "durationMs": 48120,
  "toolCalls": 34,
  "summary": "max. 200 Zeichen, Tatsache statt Vermutung",
  "failedCriteria": ["Warenkorb-Icon zeigt Positionsanzahl"],
  "evidence": ["evidence/03-warenkorb-leer.png"]
}
```

Vier Regeln in `Invoke-LlmTest.ps1` machen daraus etwas Belastbares:

1. **Keine Urteilsdatei = `failed`**, mit dem Exit-Code im Befund. Nie
   "übersprungen", nie stillschweigend grün — sonst baut sich eine grüne Pipeline
   auf, die nichts mehr testet.
2. **Timeout = `failed`**, mit eigenem Failure-Typ, damit es sich in der Historie
   von fachlichen Fehlern unterscheiden lässt.
3. **Fremde ID = `failed`.** Ein Urteil, das eine andere Test-ID trägt als der
   Auftrag nannte, wird verworfen.
4. **Widerspruch = `failed`.** `"outcome": "passed"` mit gefüllten `failedCriteria`
   ist kein bestandener Test.

Ob das Urteil vom Agenten oder vom Runner kam, steht in `verdictSource` und ist im
Testdetail sichtbar. Häufen sich `runner`-Einträge, stimmt etwas mit der Session,
nicht mit der Anwendung.

## `blocked` ist kein Testfehler

Die Trennung von `blocked` und `failed` ist die wichtigste Einzelentscheidung.
`blocked` heißt: Umgebung nicht testbar — App down, Login-Provider tot,
Zertifikatsfehler vor dem ersten Testschritt. Landet als `<skipped>` im JUnit-XML.

Ohne diese Kategorie steht man morgens vor zwanzig roten Tests und weiß nicht, ob die
Anwendung kaputt ist oder das Testsystem.

## Stabile Test-IDs

Azure DevOps korreliert die Historie über `classname` + `name`, hier gebildet aus
`LlmE2E.<suite>` und `<id> - <name>`. Wer eine ID ändert, löscht die Historie des
Testfalls und damit die Grundlage der Flaky-Erkennung. ID beim Anlegen sorgfältig
wählen, danach nie wieder anfassen — auch nicht, wenn der Test inhaltlich umgebaut
wird. `Invoke-TestSuite.ps1` bricht bei doppelten IDs ab.

## Belege

Jeder Versuch hinterlässt ein eigenes Verzeichnis:

```
artifacts/e2e/SHOP-001/attempt-1/
  prompt.md       Was der Agent beauftragt bekam
  verdict.json    Sein Urteil (fehlt, wenn er abgebrochen hat)
  stdout.log      Vollständige Session-Ausgabe
  agent-log/      Protokoll der Copilot CLI
  evidence/       Screenshots und Playwright-Traces
artifacts/e2e/SHOP-001.final.json   Das gewertete Urteil nach allen Versuchen
```

`prompt.md`, `verdict.json`, `stdout.log` und die Belege hängen in Azure DevOps direkt
am Testfall.

## Zwei Dinge, die sich lohnen

**`toolCalls` beobachten.** Springt ein Test von 30 auf 200 Tool-Calls, probiert der
Agent Selektoren durch. Das sieht man in der Historie, bevor der Test rot wird — und
es kostet Tokens.

**Golden-Run-Gate.** Bevor eine neue Spec in die Suite darf: dreimal gegen eine
bekannt gute Umgebung laufen lassen. Nicht dreimal grün heißt in aller Regel, dass die
Spec zu vage formuliert ist, nicht dass die Anwendung kaputt ist.

## Offene Punkte

- **Nicht ausgeführt.** Weder die PowerShell-Skripte noch `junit.cs` sind je gelaufen.
- **Copilot-CLI-Flags.** Die CLI ist Preview; `copilot --help` prüfen und die
  Argumentliste in `Invoke-LlmTest.ps1` anpassen. Falls die Version keinen Prompt als
  Argument annimmt, über eine Datei oder stdin übergeben.
- **Paralleles Ausführen innerhalb eines Jobs** gibt es nicht — nur Slicing über
  mehrere Jobs. Für den Anfang reicht das meist.

## Beispielaufrufe

.\platform\tools\Invoke-LlmTest.ps1 tests\specs\SHOP-001.md .\out -PromptTemplate tests\prompt.template.md -McpConfig platform\.copilot

.\platform\tools\Invoke-LlmTest.ps1 tests\specs\SHOP-001.md .\out

.\platform\tools\Invoke-TestSuite.ps1 .\out .\tests\specs\ meinapetito

## Points to notice

Playwright Version von MCP Server und der Playwright installation in der Pipeline, wo auch die Browser-Version festegelegt werdne müssen zusammen passen. Die Version des Browsers muss darüber hinaus auch noch mit dem OS Image kompatibel sein das die Pipeline verwendet (das kann zu Problemen fürhen wenn dort z.B. ubunut-latest verwendet wird und die neue OS Version die benötigte Browser-Version nicht unterstützt).
