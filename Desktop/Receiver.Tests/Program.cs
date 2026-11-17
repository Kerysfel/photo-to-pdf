using System.Buffers.Binary;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using PhotoToPdf.Receiver;

var folder = Path.Combine(Path.GetTempPath(), "phototopdf-test-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(folder);
try
{
    TestUpdateSelection();
    await RejectWrongCertificate();
    await Run("success");
    await Run("wrong-secret");
    await Run("wrong-hash");
    await Run("interrupted");
    Console.WriteLine("All receiver tests passed.");
}
finally { Directory.Delete(folder, true); }

static void TestUpdateSelection()
{
    string hash = new string('a', 64);
    string json = $$"""
    [
      {"draft":false,"tag_name":"v1.4.0-preview.3","assets":[{"name":"PhotoToPDF-Receiver-Windows-x64-Setup.exe","browser_download_url":"https://github.com/Kerysfel/photo-to-pdf/releases/download/v1.4.0-preview.3/PhotoToPDF-Receiver-Windows-x64-Setup.exe","digest":"sha256:{{hash}}","size":100}]},
      {"draft":false,"tag_name":"v1.5.0-preview.1","assets":[{"name":"PhotoToPDF-Receiver-Windows-x64-Setup.exe","browser_download_url":"https://example.com/evil.exe","digest":"sha256:{{hash}}","size":100}]},
      {"draft":true,"tag_name":"v2.0.0","assets":[]}
    ]
    """;
    using var document = JsonDocument.Parse(json);
    if (Updates.FindLatest(document.RootElement, "v1.4.0-preview.2")?.Tag != "v1.4.0-preview.3")
        throw new Exception("Update selection failed");
    if (Updates.FindLatest(document.RootElement, "v1.4.0") != null)
        throw new Exception("Update selection offered an older preview");
    Console.WriteLine("update-selection: passed");
}

async Task Run(string mode)
{
    using var receiver = new Receiver();
    var invite = JsonDocument.Parse(receiver.Invitation(IPAddress.Loopback)).RootElement;
    var receive = receiver.ReceiveAsync(folder, (_, _) => Task.FromResult(true), new Progress<double>());
    using var client = new TcpClient();
    await client.ConnectAsync(IPAddress.Loopback, invite.GetProperty("port").GetInt32());
    var fingerprint = invite.GetProperty("certificateSha256").GetString();
    await using var tls = new SslStream(client.GetStream(), false, (_, cert, _, _) =>
        cert != null && Convert.ToHexString(SHA256.HashData(cert.GetRawCertData())).Equals(fingerprint, StringComparison.OrdinalIgnoreCase));
    await tls.AuthenticateAsClientAsync("localhost");
    var payload = "%PDF-1.4\nexample\n%%EOF"u8.ToArray();
    await Write(tls, new { secret = mode == "wrong-secret" ? Convert.ToBase64String(new byte[32]) : invite.GetProperty("secret").GetString(), name = mode + ".pdf", size = payload.Length });
    if (mode != "wrong-secret")
    {
        var status = await Read(tls);
        if (status.GetProperty("status").GetString() != "accepted") throw new Exception("Offer not accepted");
        await tls.WriteAsync(mode == "interrupted" ? payload.AsMemory(0, 5) : payload);
        if (mode != "interrupted") await Write(tls, new { sha256 = Convert.ToHexString(mode == "wrong-hash" ? new byte[32] : SHA256.HashData(payload)) });
    }
    if (mode == "interrupted") client.Dispose();
    if (mode == "success")
    {
        var status = await Read(tls);
        if (status.GetProperty("status").GetString() != "saved") throw new Exception("No saved acknowledgement");
        var path = await receive;
        if (!File.ReadAllBytes(path).SequenceEqual(payload)) throw new Exception("File mismatch");
    }
    else
    {
        try { await receive; throw new Exception(mode + " unexpectedly succeeded"); }
        catch (Exception e) when (e is InvalidDataException or EndOfStreamException or IOException) { }
        if (Directory.GetFiles(folder, "*.part").Length != 0 || File.Exists(Path.Combine(folder, mode + ".pdf"))) throw new Exception("Incomplete file left behind");
    }
    Console.WriteLine(mode + ": passed");
}
static async Task Write(Stream stream, object value)
{
    byte[] body = JsonSerializer.SerializeToUtf8Bytes(value), header = new byte[4];
    BinaryPrimitives.WriteInt32BigEndian(header, body.Length);
    await stream.WriteAsync(header); await stream.WriteAsync(body); await stream.FlushAsync();
}
static async Task<JsonElement> Read(Stream stream)
{
    byte[] header = new byte[4]; await stream.ReadExactlyAsync(header);
    byte[] body = new byte[BinaryPrimitives.ReadInt32BigEndian(header)]; await stream.ReadExactlyAsync(body);
    return JsonDocument.Parse(body).RootElement;
}

async Task RejectWrongCertificate()
{
    using var receiver = new Receiver();
    var invite = JsonDocument.Parse(receiver.Invitation(IPAddress.Loopback)).RootElement;
    var receive = receiver.ReceiveAsync(folder, (_, _) => Task.FromResult(true), new Progress<double>());
    using var client = new TcpClient();
    await client.ConnectAsync(IPAddress.Loopback, invite.GetProperty("port").GetInt32());
    await using var tls = new SslStream(client.GetStream(), false, (_, cert, _, _) =>
        cert != null && CryptographicOperations.FixedTimeEquals(SHA256.HashData(cert.GetRawCertData()), new byte[32]));
    try { await tls.AuthenticateAsClientAsync("localhost"); throw new Exception("Wrong certificate accepted"); }
    catch (System.Security.Authentication.AuthenticationException) { }
    client.Dispose();
    try { await receive; throw new Exception("Receiver accepted rejected handshake"); }
    catch (Exception e) when (e is System.Security.Authentication.AuthenticationException or IOException) { }
    Console.WriteLine("wrong-certificate: passed");
}
