#!/usr/bin/env dotnet
#:property PublishAot=false

// Übersetzt die Urteile der Agent-Sessions in JUnit-XML.
// Damit sehen die Ergebnisse in Azure DevOps aus wie Unit-Tests: Tests-Tab,
// Historie, Flaky-Erkennung, Fehlermeldung und Screenshot am einzelnen Testfall.
//
//   dotnet run tools/junit.cs -- --in artifacts/e2e --out artifacts/e2e/junit.xml
//
// Einzelne Datei, keine NuGet-Pakete - läuft auch auf Agents ohne nuget.org-Zugang.

using System.Text;
using System.Text.Json;
using System.Xml.Linq;

var inDir = GetArg("--in");
if (inDir is null) return Fail("--in ist erforderlich.");

var outFile = GetArg("--out") ?? Path.Combine(inDir, "junit.xml");
var summaryFile = GetArg("--summary") ?? Path.Combine(inDir, "summary.md");

if (!Directory.Exists(inDir)) return Fail($"Verzeichnis nicht gefunden: {inDir}");

var jsonOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    ReadCommentHandling = JsonCommentHandling.Skip,
    AllowTrailingCommas = true
};

var verdicts = new List<Verdict>();
foreach (var file in Directory.EnumerateFiles(inDir, "*.final.json", SearchOption.AllDirectories))
{
    try
    {
        var v = JsonSerializer.Deserialize<Verdict>(File.ReadAllText(file), jsonOptions);
        if (v is not null) verdicts.Add(v);
    }
    catch (JsonException ex)
    {
        Console.Error.WriteLine($"warn: {file} übersprungen ({ex.Message})");
    }
}

if (verdicts.Count == 0)
{
    // Kein einziges Urteil heißt: Abbruch vor der ersten Session. Darf nicht
    // als grüne Pipeline durchgehen.
    Console.Error.WriteLine($"error: keine *.final.json unter {inDir} gefunden.");
    return 1;
}

verdicts = verdicts
    .OrderBy(v => v.Suite, StringComparer.Ordinal)
    .ThenBy(v => v.Id, StringComparer.Ordinal)
    .ToList();

WriteJUnit(verdicts, outFile);
WriteSummary(verdicts, summaryFile);

if (Environment.GetEnvironmentVariable("TF_BUILD") is "True" or "true")
    Console.WriteLine($"##vso[task.uploadsummary]{Path.GetFullPath(summaryFile)}");

var failedCount = verdicts.Count(v => v.Outcome == "failed");
var blockedCount = verdicts.Count(v => v.Outcome == "blocked");
Console.WriteLine($"{verdicts.Count} Urteile verarbeitet "
                  + $"({verdicts.Count - failedCount - blockedCount} bestanden, "
                  + $"{failedCount} fehlgeschlagen, {blockedCount} blockiert).");
Console.WriteLine($"  JUnit: {Path.GetFullPath(outFile)}");
return 0;

// ---------------------------------------------------------------------------

void WriteJUnit(List<Verdict> all, string path)
{
    var suites = all
        .GroupBy(v => string.IsNullOrWhiteSpace(v.Suite) ? "E2E" : v.Suite!, StringComparer.Ordinal)
        .Select(g => new XElement("testsuite",
            new XAttribute("name", $"LlmE2E.{g.Key}"),
            new XAttribute("tests", g.Count()),
            new XAttribute("failures", g.Count(v => v.Outcome == "failed")),
            new XAttribute("skipped", g.Count(v => v.Outcome == "blocked")),
            new XAttribute("errors", 0),
            new XAttribute("time", Seconds(g.Sum(v => v.WallMs))),
            new XAttribute("timestamp", DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss")),
            g.Select(v => TestCase(v, g.Key))));

    var doc = new XDocument(new XElement("testsuites",
        new XAttribute("name", "LLM-E2E"),
        new XAttribute("tests", all.Count),
        new XAttribute("failures", all.Count(v => v.Outcome == "failed")),
        new XAttribute("time", Seconds(all.Sum(v => v.WallMs))),
        suites));

    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
    doc.Save(path);
}

// classname + name bilden die Test-Identität in Azure DevOps. Ändert sich einer
// der beiden Teile, gilt der Test als neu und die Historie ist weg.
XElement TestCase(Verdict v, string suiteKey)
{
    var tc = new XElement("testcase",
        new XAttribute("name", $"{v.Id} - {v.Name}"),
        new XAttribute("classname", $"LlmE2E.{suiteKey}"),
        new XAttribute("time", Seconds(v.WallMs)));

    if (v.Outcome == "failed")
    {
        var detail = new StringBuilder();
        detail.AppendLine(v.Summary);
        if (v.FailedCriteria is { Length: > 0 })
        {
            detail.AppendLine().AppendLine("Nicht erfüllte Kriterien:");
            foreach (var c in v.FailedCriteria) detail.AppendLine($"  - {c}");
        }
        detail.AppendLine().AppendLine($"Spec: {v.SourcePath}");
        detail.AppendLine($"Versuche: {v.Attempt}/{v.MaxAttempts}, Tool-Calls: {v.ToolCalls}");
        if (v.TimedOut) detail.AppendLine("Session wurde wegen Timeout abgebrochen.");

        tc.Add(new XElement("failure",
            new XAttribute("message", Truncate(v.Summary, 400)),
            new XAttribute("type", v.TimedOut ? "TimeoutFailure" : "AssertionFailure"),
            new XCData(detail.ToString())));
    }
    else if (v.Outcome == "blocked")
    {
        // Umgebungsproblem, kein Testfehler.
        tc.Add(new XElement("skipped",
            new XAttribute("message", Truncate($"BLOCKED: {v.Summary}", 400))));
    }

    tc.Add(new XElement("properties",
        Prop("testId", v.Id),
        Prop("attempts", v.Attempt.ToString()),
        Prop("toolCalls", v.ToolCalls.ToString()),
        Prop("verdictSource", v.VerdictSource),
        Prop("tags", string.Join(',', v.Tags ?? []))));

    // Screenshots, Traces und Agent-Log an das Testergebnis hängen.
    var sysOut = new StringBuilder();
    sysOut.AppendLine($"Outcome: {v.Outcome} | Versuche: {v.Attempt}/{v.MaxAttempts} "
                      + $"| Tool-Calls: {v.ToolCalls} | Urteil von: {v.VerdictSource}");
    sysOut.AppendLine(v.Summary);
    foreach (var p in Attachments(v)) sysOut.AppendLine($"[[ATTACHMENT|{p}]]");

    tc.Add(new XElement("system-out", new XCData(sysOut.ToString())));
    return tc;
}

IEnumerable<string> Attachments(Verdict v)
{
    if (string.IsNullOrWhiteSpace(v.ArtifactDir)) yield break;

    foreach (var name in new[] { "verdict.json", "prompt.md", "stdout.log", "stderr.log" })
    {
        var p = Path.GetFullPath(Path.Combine(v.ArtifactDir, name));
        if (File.Exists(p)) yield return p;
    }

    foreach (var evidence in (v.Evidence ?? []).Take(25))
    {
        var p = Path.IsPathRooted(evidence)
            ? evidence
            : Path.GetFullPath(Path.Combine(v.ArtifactDir, evidence));
        if (File.Exists(p)) yield return p;
    }
}

void WriteSummary(List<Verdict> all, string path)
{
    var failed = all.Count(v => v.Outcome == "failed");
    var blocked = all.Count(v => v.Outcome == "blocked");

    var sb = new StringBuilder();
    sb.AppendLine("## LLM-E2E-Ergebnisse").AppendLine();
    sb.AppendLine($"**{all.Count - failed - blocked} bestanden**, **{failed} fehlgeschlagen**, "
                  + $"{blocked} blockiert — {all.Sum(v => v.ToolCalls)} Tool-Calls, "
                  + $"{TimeSpan.FromMilliseconds(all.Sum(v => v.WallMs)):hh\\:mm\\:ss} Laufzeit")
      .AppendLine();

    if (blocked > 0)
        sb.AppendLine("> Blockierte Tests deuten auf ein Umgebungsproblem, nicht auf eine Regression.")
          .AppendLine();

    sb.AppendLine("| | ID | Testfall | Dauer | Vers. | Tool-Calls | Befund |");
    sb.AppendLine("|---|---|---|---:|---:|---:|---|");

    foreach (var v in all.OrderBy(v => v.Outcome switch { "failed" => 0, "blocked" => 1, _ => 2 })
                         .ThenBy(v => v.Id, StringComparer.Ordinal))
    {
        var icon = v.Outcome switch { "passed" => "PASS", "blocked" => "BLOCK", _ => "FAIL" };
        sb.AppendLine($"| {icon} | `{v.Id}` | {Escape(v.Name)} | {v.WallMs / 1000}s "
                      + $"| {v.Attempt} | {v.ToolCalls} | {Escape(Truncate(v.Summary, 160))} |");
    }

    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
    File.WriteAllText(path, sb.ToString(), Encoding.UTF8);
}

XElement Prop(string name, string? value)
    => new("property", new XAttribute("name", name), new XAttribute("value", value ?? ""));

string Seconds(long ms) => (ms / 1000.0).ToString("F2");

string Truncate(string? s, int max)
    => string.IsNullOrEmpty(s) ? "" : s.Length <= max ? s : s[..max] + " ...";

string Escape(string? s) => (s ?? "").Replace("|", "\\|").Replace("\n", " ");

string? GetArg(string name)
{
    var i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}

int Fail(string message)
{
    Console.Error.WriteLine($"error: {message}");
    Console.Error.WriteLine("usage: dotnet run tools/junit.cs -- --in <dir> [--out <datei>] [--summary <datei>]");
    Environment.Exit(64);
    return 64;
}

// Felder, die PowerShell in die *.final.json schreibt.
sealed class Verdict
{
    public string Id { get; set; } = "";
    public string? Name { get; set; }
    public string? Suite { get; set; }
    public string Outcome { get; set; } = "failed";
    public string Summary { get; set; } = "";
    public string[]? FailedCriteria { get; set; }
    public string[]? Evidence { get; set; }
    public string[]? Tags { get; set; }
    public int ToolCalls { get; set; }
    public int Attempt { get; set; }
    public int MaxAttempts { get; set; }
    public long WallMs { get; set; }
    public bool TimedOut { get; set; }
    public string? ArtifactDir { get; set; }
    public string? SourcePath { get; set; }
    public string VerdictSource { get; set; } = "runner";
}
