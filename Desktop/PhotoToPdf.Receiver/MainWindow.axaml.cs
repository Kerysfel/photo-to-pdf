using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using QRCoder;

namespace PhotoToPdf.Receiver;

public partial class MainWindow : Window
{
    private Receiver? receiver;
    private TaskCompletionSource<bool>? confirmation;
    private AvailableUpdate? availableUpdate;
    private readonly CancellationTokenSource updateCancellation = new();
    private string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Фото в PDF");

    public MainWindow()
    {
        InitializeComponent();
        FolderText.Text = folder;
        var addresses = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .OrderBy(n => n.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet ? 0 : 1)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses
                .Select(a => new NetworkAddress(n.Name, a.Address)))
            .Where(a => IsLocalAddress(a.Address))
            .DistinctBy(a => a.Address).ToArray();
        Addresses.ItemsSource = addresses;
        if (addresses.Length > 0) Addresses.SelectedIndex = 0;
        Opened += async (_, _) => { Updates.CleanOldInstallers(); await RefreshUpdates(); };
        Closed += (_, _) => { updateCancellation.Cancel(); confirmation?.TrySetResult(false); receiver?.Dispose(); };
    }

    private async void ChooseFolder(object? sender, RoutedEventArgs e)
    {
        var selected = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Папка для PDF", AllowMultiple = false });
        if (selected.Count == 1 && selected[0].TryGetLocalPath() is string path) { folder = path; FolderText.Text = path; }
    }

    private async void Start(object? sender, RoutedEventArgs e)
    {
        if (Addresses.SelectedItem is not NetworkAddress selected) { Status.Text = "Локальный адрес не найден"; Detail.Text = "Подключите компьютер к локальной сети и перезапустите приложение."; return; }
        try
        {
            var session = new Receiver();
            receiver = session;
            using var generator = new QRCodeGenerator();
            using var data = generator.CreateQrCode(session.Invitation(selected.Address), QRCodeGenerator.ECCLevel.Q);
            using var png = new MemoryStream(new PngByteQRCode(data).GetGraphic(5));
            QrImage.Source = new Bitmap(png);
            QrImage.IsVisible = true;
            Status.Text = "Ожидание подключения";
            Detail.Text = "Отсканируйте QR-код в приложении на телефоне.";
            StartButton.IsEnabled = false; StopButton.IsEnabled = true; Addresses.IsEnabled = false;
            var result = await session.ReceiveAsync(folder, ConfirmAsync, new Progress<double>(p => { Progress.IsVisible = true; Progress.Value = p * 100; }));
            Status.Text = "Файл сохранён"; Detail.Text = result;
        }
        catch (OperationCanceledException) { Status.Text = "Приём остановлен"; Detail.Text = ""; }
        catch (Exception ex) { Status.Text = "Не удалось получить файл"; Detail.Text = ex.Message; }
        finally
        {
            receiver?.Dispose(); receiver = null; confirmation = null;
            QrImage.IsVisible = false; QrImage.Source = null; ConfirmPanel.IsVisible = false; Progress.IsVisible = false;
            StartButton.IsEnabled = true; StopButton.IsEnabled = false; Addresses.IsEnabled = true;
        }
    }

    private Task<bool> ConfirmAsync(string name, long size)
    {
        QrImage.IsVisible = false;
        Status.Text = "Подтвердите получение";
        Detail.Text = $"{name} · {size / 1048576.0:F1} МБ";
        ConfirmPanel.IsVisible = true;
        confirmation = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        return confirmation.Task;
    }
    private void Accept(object? sender, RoutedEventArgs e) { ConfirmPanel.IsVisible = false; Status.Text = "Получение файла"; confirmation?.TrySetResult(true); }
    private void Reject(object? sender, RoutedEventArgs e) => confirmation?.TrySetResult(false);
    private void Stop(object? sender, RoutedEventArgs e) { confirmation?.TrySetResult(false); receiver?.Dispose(); receiver = null; }

    private async void CheckUpdates(object? sender, RoutedEventArgs e) => await RefreshUpdates();

    private async Task RefreshUpdates()
    {
        CheckUpdateButton.IsEnabled = false;
        UpdateStatus.Text = "Проверка обновлений на GitHub…";
        try
        {
            availableUpdate = await Updates.CheckAsync(updateCancellation.Token);
            UpdateButton.IsVisible = availableUpdate != null;
            UpdateStatus.Text = availableUpdate == null ? $"Версия {Updates.CurrentTag}: обновлений нет." :
                $"Доступна версия {availableUpdate.Tag}. Установщик будет загружен с GitHub и запущен после нажатия кнопки.";
        }
        catch (OperationCanceledException) { }
        catch (Exception) { UpdateStatus.Text = "Не удалось проверить обновления. Проверьте подключение к интернету."; }
        finally { CheckUpdateButton.IsEnabled = true; }
    }

    private async void InstallUpdate(object? sender, RoutedEventArgs e)
    {
        if (availableUpdate == null) return;
        if (receiver != null) { UpdateStatus.Text = "Сначала остановите приём файла."; return; }
        UpdateButton.IsEnabled = false;
        CheckUpdateButton.IsEnabled = false;
        StartButton.IsEnabled = false;
        try
        {
            UpdateStatus.Text = "Загрузка и проверка установщика…";
            var path = await Updates.DownloadAsync(availableUpdate, updateCancellation.Token);
            if (Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }) == null)
                throw new InvalidOperationException("Не удалось запустить установщик.");
            Close();
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { UpdateStatus.Text = $"Не удалось установить обновление: {error.Message}"; }
        finally { UpdateButton.IsEnabled = true; CheckUpdateButton.IsEnabled = true; StartButton.IsEnabled = true; }
    }

    private static bool IsLocalAddress(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        var b = address.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) ||
               (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
    }

    private sealed record NetworkAddress(string Name, IPAddress Address)
    {
        public override string ToString() => $"{Name} — {Address}";
    }
}
