# ADR 0001: Playwright, Playwright MCP, Chromium und OS-Image zusammen betrachten

Status: akzeptiert

## Kontext

Die E2E-Tests laufen über die Copilot CLI mit dem Playwright-MCP-Server
(`@playwright/mcp`). In der Pipeline traten zwei Fehlerbilder auf:

1. **`Playwright does not support chromium on ubuntu26.04-x64`**
   `ubuntu-latest` zeigt jetzt auf Ubuntu 26.04. Die gepinnte Version
   `playwright@1.56.0-alpha-2025-10-01` kennt dieses OS nicht und kann
   Chromium bzw. die Systemabhängigkeiten nicht installieren.
2. **Agent meldet "keine Playwright-MCP-Tools verfügbar"** bei grüner Pipeline.
   Nach dem Entpinnen auf `@playwright/mcp@latest` (0.0.83) wurde der Parameter
   `--save-trace` entfernt. Der MCP-Server beendet sich dann beim Start mit
   `error: unknown option '--save-trace'`. Die Copilot CLI startet trotzdem,
   der Agent hat aber keine Tools und bricht den Test ordnungsgemäß ab. Weder
   `copilot mcp list` noch `copilot mcp get` starten den Server und merken das.

## Zusammenhang der Versionen

```
@playwright/mcp@X  --(exakte Abhängigkeit)-->  playwright / playwright-core@Y
                                                   |
                                                   +--> erwartet Chromium-Revision R (in Y fest verdrahtet)
                                                   +--> unterstützt nur bestimmte OS-Versionen
                                                        (für `install --with-deps`)
```

- Der MCP-Server hängt exakt an einer Playwright-Version (`dependencies.playwright`).
- Diese Playwright-Version bestimmt, welche Chromium-Revision der Server sucht.
  Der Browser muss daher mit **derselben** Playwright-Version `Y` installiert
  werden, sonst meldet der Server "browser not installed".
- Jede Playwright-Version hat eine Liste unterstützter Linux-Distributionen.
  Ist das Runner-OS nicht enthalten, scheitert `install --with-deps`.
  Alte Versionen kennen neue OS-Releases nicht.
- Auch Parameter und Tool-Namen des MCP-Servers ändern sich zwischen Versionen
  (Beispiel `--save-trace`; Tracing geht jetzt nur noch über `--caps devtools`).

## Entscheidung

- MCP-Version wird nicht gepinnt (`@playwright/mcp@latest`), damit neue
  Runner-Images unterstützt werden.
- Die Pipeline leitet die Playwright-Version aus
  `npm view @playwright/mcp@latest dependencies.playwright` ab und installiert
  Chromium damit. Browser und MCP passen so immer zusammen.
  `--with-deps` wird versucht, bei Fehler folgt eine Installation ohne
  Systempakete (die Microsoft-hosted Images bringen das meiste mit).
- Die Pipeline startet den MCP-Server aus der Konfiguration und sendet ein
  `initialize`. Antwortet er nicht, schlägt der Schritt fehl. So wird ein
  nicht startender Server nicht mehr zu einem stillen "keine Tools"-Ergebnis.
- `--save-trace` wurde aus beiden `mcp-config.json` entfernt.

## Konsequenzen

- Kein Pflegeaufwand für Versionspins, dafür kann ein neues MCP-Release die
  Konfiguration brechen. Das fällt jetzt im Smoke-Test der Pipeline auf.
- Playwright-Traces werden aktuell nicht mehr automatisch geschrieben.
  Bei Bedarf `--caps devtools` ergänzen und im Prompt das Tracing anfordern.
- Fallback bei Problemen mit einem neuen MCP-Release: MCP-Version pinnen,
  Playwright-Version im Install-Schritt passend fest setzen **und** `vmImage`
  auf ein von dieser Version unterstütztes Image pinnen (z. B. `ubuntu-24.04`).
- Bei "keine Tools verfügbar" zuerst den MCP-Server manuell mit den Parametern
  aus `mcp-config.json` starten und die Fehlerausgabe lesen.
