using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PhotoToPdf.Receiver;

internal sealed record AvailableUpdate(string Tag, string DownloadUrl, string Sha256, long Size);

internal static partial class Updates
{
    // Release tag of the running build. Only releases with Windows x64 installers are offered.
    public const string CurrentTag = "v1.6.0-preview.1";
    private const long MaxInstallerSize = 200L * 1024 * 1024;
    private static readonly string UpdateDirectory = Path.Combine(Path.GetTempPath(), "PhotoToPDF-Receiver-Updates");
    private static readonly HttpClient Http = CreateHttpClient();

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("PhotoToPDF-Receiver/1.4");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    public static async Task<AvailableUpdate?> CheckAsync(CancellationToken ct)
    {
        using var response = await Http.GetAsync("https://api.github.com/repos/Kerysfel/photo-to-pdf/releases?per_page=30", ct);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var json = await JsonDocument.ParseAsync(stream, cancellationToken: ct);
        return FindLatest(json.RootElement, CurrentTag);
    }

    internal static AvailableUpdate? FindLatest(JsonElement releases, string currentTag)
    {
        var current = ParseTag(currentTag) ?? throw new InvalidOperationException("Недопустимая версия приложения.");
        AvailableUpdate? result = null;
        var newest = current;
        foreach (var release in releases.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean()) continue;
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            var version = ParseTag(tag);
            if (version == null || version.Value.CompareTo(newest) <= 0) continue;
            foreach (var asset in release.GetProperty("assets").EnumerateArray())
            {
                var name = asset.GetProperty("name").GetString() ?? "";
                var url = asset.GetProperty("browser_download_url").GetString() ?? "";
                var digest = asset.TryGetProperty("digest", out var d) ? d.GetString() : null;
                var size = asset.GetProperty("size").GetInt64();
                var expectedUrl = $"https://github.com/Kerysfel/photo-to-pdf/releases/download/{tag}/{name}";
                if (!name.StartsWith("PhotoToPDF-Receiver-Windows-x64-Setup", StringComparison.Ordinal) ||
                    !name.EndsWith(".exe", StringComparison.Ordinal) || name.Contains('/') || name.Contains('\\') ||
                    url != expectedUrl || size <= 0 || size > MaxInstallerSize ||
                    digest == null || !ShaPattern().IsMatch(digest)) continue;
                result = new AvailableUpdate(tag, url, digest[7..], size);
                newest = version.Value;
                break;
            }
        }
        return result;
    }

    public static async Task<string> DownloadAsync(AvailableUpdate update, CancellationToken ct)
    {
        Directory.CreateDirectory(UpdateDirectory);
        var path = Path.Combine(UpdateDirectory, $"PhotoToPDF-Setup-{Guid.NewGuid():N}.exe");
        try
        {
            using var response = await Http.GetAsync(update.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();
            await using var input = await response.Content.ReadAsStreamAsync(ct);
            await using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            byte[] buffer = new byte[65536];
            long total = 0;
            int count;
            while ((count = await input.ReadAsync(buffer, ct)) != 0)
            {
                total += count;
                if (total > update.Size || total > MaxInstallerSize) throw new InvalidDataException("Размер установщика не совпадает.");
                hash.AppendData(buffer, 0, count);
                await output.WriteAsync(buffer.AsMemory(0, count), ct);
            }
            if (total != update.Size || !CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(update.Sha256)))
                throw new InvalidDataException("Контрольная сумма установщика не совпадает.");
            await output.DisposeAsync();
            if (OperatingSystem.IsWindows())
                await File.WriteAllTextAsync(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n", ct);
            return path;
        }
        catch { TryDelete(path); throw; }
    }

    public static void CleanOldInstallers()
    {
        try
        {
            if (!Directory.Exists(UpdateDirectory)) return;
            foreach (var file in Directory.EnumerateFiles(UpdateDirectory, "PhotoToPDF-Setup-*.exe")) TryDelete(file);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void TryDelete(string path) { try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { } }

    // Stable releases sort after previews of the same version.
    private static (int Major, int Minor, int Patch, int Preview)? ParseTag(string tag)
    {
        var match = TagPattern().Match(tag);
        if (!match.Success || !int.TryParse(match.Groups[1].Value, out int major) ||
            !int.TryParse(match.Groups[2].Value, out int minor) || !int.TryParse(match.Groups[3].Value, out int patch)) return null;
        int preview = int.MaxValue;
        if (match.Groups[4].Success && !int.TryParse(match.Groups[4].Value, out preview)) return null;
        return (major, minor, patch, preview);
    }

    [GeneratedRegex(@"^v(\d+)\.(\d+)\.(\d+)(?:-preview\.(\d+))?$", RegexOptions.CultureInvariant)]
    private static partial Regex TagPattern();
    [GeneratedRegex(@"^sha256:[0-9a-fA-F]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex ShaPattern();
}
