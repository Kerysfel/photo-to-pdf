using System.Buffers.Binary;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace PhotoToPdf.Receiver;

// One invitation accepts at most one authenticated transfer.
internal sealed class Receiver : IDisposable
{
    private const long MaxFileSize = 2L * 1024 * 1024 * 1024;
    private readonly TcpListener listener = new(IPAddress.Any, 0);
    private readonly ECDsa key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    private readonly X509Certificate2 certificate;
    private readonly byte[] secret = RandomNumberGenerator.GetBytes(32);
    private readonly CancellationTokenSource stop = new();
    private TcpClient? client;
    private int disposed;

    public Receiver()
    {
        var request = new CertificateRequest("CN=PhotoToPDF Receiver", key, HashAlgorithmName.SHA256);
        certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddDays(1));
        listener.Start(1);
    }

    public string Invitation(IPAddress address) => JsonSerializer.Serialize(new
    {
        version = 1, host = address.ToString(), port = ((IPEndPoint)listener.LocalEndpoint).Port,
        certificateSha256 = Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant(),
        secret = Convert.ToBase64String(secret)
    });

    public async Task<string> ReceiveAsync(string folder, Func<string, long, Task<bool>> confirm,
        IProgress<double> progress)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
        deadline.CancelAfter(TimeSpan.FromMinutes(10));
        var ct = deadline.Token;
        string? temporary = null;
        try
        {
            client = await listener.AcceptTcpClientAsync(ct);
            listener.Stop();
            await using var tls = new SslStream(client.GetStream());
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = certificate,
                EnabledSslProtocols = System.Security.Authentication.SslProtocols.Tls12 | System.Security.Authentication.SslProtocols.Tls13
            }, ct);
            var hello = await ReadMessageAsync<Offer>(tls, ct);
            byte[] supplied;
            try { supplied = Convert.FromBase64String(hello.Secret ?? ""); }
            catch (FormatException) { throw new InvalidDataException("Неверный ключ подключения."); }
            if (supplied.Length != secret.Length || !CryptographicOperations.FixedTimeEquals(secret, supplied))
                throw new InvalidDataException("Неверный ключ подключения.");
            if (hello.Size <= 0 || hello.Size > MaxFileSize || string.IsNullOrWhiteSpace(hello.Name) || hello.Name.Length > 200 ||
                hello.Name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || hello.Name.Contains('/') || hello.Name.Contains('\\') ||
                !hello.Name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Недопустимое имя или размер файла.");
            if (!await confirm(hello.Name, hello.Size).WaitAsync(ct))
            {
                await WriteMessageAsync(tls, new { status = "rejected" }, ct);
                throw new OperationCanceledException("Получение отклонено.");
            }
            await WriteMessageAsync(tls, new { status = "accepted" }, ct);
            Directory.CreateDirectory(folder);
            temporary = Path.Combine(folder, ".phototopdf-" + Guid.NewGuid().ToString("N") + ".part");
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                byte[] buffer = new byte[65536];
                long remaining = hello.Size;
                while (remaining > 0)
                {
                    int count = await tls.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), ct);
                    if (count == 0) throw new EndOfStreamException("Передача прервана.");
                    await output.WriteAsync(buffer.AsMemory(0, count), ct);
                    digest.AppendData(buffer, 0, count);
                    remaining -= count;
                    progress.Report((double)(hello.Size - remaining) / hello.Size);
                }
                await output.FlushAsync(ct);
            }
            var trailer = await ReadMessageAsync<Trailer>(tls, ct);
            byte[] expected;
            try { expected = Convert.FromHexString(trailer.Sha256 ?? ""); }
            catch (FormatException) { throw new InvalidDataException("Неверная контрольная сумма."); }
            if (!CryptographicOperations.FixedTimeEquals(digest.GetHashAndReset(), expected))
                throw new InvalidDataException("Контрольная сумма не совпадает.");
            var name = Path.GetFileNameWithoutExtension(hello.Name);
            string destination = Path.Combine(folder, hello.Name);
            for (int suffix = 1; ; suffix++)
            {
                try { File.Move(temporary, destination, false); break; }
                catch (IOException) when (File.Exists(destination)) { destination = Path.Combine(folder, $"{name} ({suffix}).pdf"); }
            }
            temporary = null;
            try { await WriteMessageAsync(tls, new { status = "saved" }, ct); }
            catch (IOException) { /* The file is saved even if the acknowledgement is lost. */ }
            return destination;
        }
        finally
        {
            if (temporary != null) { try { File.Delete(temporary); } catch (IOException) { } }
        }
    }

    private static async Task<T> ReadMessageAsync<T>(Stream stream, CancellationToken ct)
    {
        byte[] header = new byte[4];
        await stream.ReadExactlyAsync(header, ct);
        int length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length <= 0 || length > 4096) throw new InvalidDataException("Недопустимое сообщение.");
        byte[] bytes = new byte[length];
        await stream.ReadExactlyAsync(bytes, ct);
        return JsonSerializer.Deserialize<T>(bytes, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidDataException("Пустое сообщение.");
    }

    private static async Task WriteMessageAsync(Stream stream, object value, CancellationToken ct)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        byte[] header = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(header, bytes.Length);
        await stream.WriteAsync(header, ct);
        await stream.WriteAsync(bytes, ct);
        await stream.FlushAsync(ct);
    }

    public void Dispose() { if (Interlocked.Exchange(ref disposed, 1) != 0) return; stop.Cancel(); listener.Stop(); client?.Dispose(); certificate.Dispose(); key.Dispose(); stop.Dispose(); }
    private sealed record Offer(string? Secret, string? Name, long Size);
    private sealed record Trailer(string? Sha256);
}
