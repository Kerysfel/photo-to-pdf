using System.Text.Json;

namespace PhotoToPdf.Receiver;

internal sealed class ReceiverSettings
{
    private readonly string path;

    public ReceiverSettings(string directory) => path = Path.Combine(directory, "settings.json");

    public string? LoadFolder()
    {
        if (!File.Exists(path)) return null;
        var settings = JsonSerializer.Deserialize<Values>(File.ReadAllText(path));
        return settings?.Folder is { Length: > 0 } folder && Path.IsPathFullyQualified(folder) ? folder : null;
    }

    public void SaveFolder(string folder)
    {
        if (!Path.IsPathFullyQualified(folder)) throw new ArgumentException("Укажите полный путь к папке.");
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $"settings-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(new Values(folder)));
            File.Move(temporary, path, true);
        }
        finally
        {
            try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private sealed record Values(string Folder);
}
