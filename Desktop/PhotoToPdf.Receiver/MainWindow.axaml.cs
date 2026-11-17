using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
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
    private string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Фото в PDF");

    public MainWindow()
    {
        InitializeComponent();
        FolderText.Text = folder;
        var addresses = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address).Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
            .Distinct().ToArray();
        Addresses.ItemsSource = addresses;
        if (addresses.Length > 0) Addresses.SelectedIndex = 0;
        Closed += (_, _) => { confirmation?.TrySetResult(false); receiver?.Dispose(); };
    }

    private async void ChooseFolder(object? sender, RoutedEventArgs e)
    {
        var selected = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Папка для PDF", AllowMultiple = false });
        if (selected.Count == 1 && selected[0].TryGetLocalPath() is string path) { folder = path; FolderText.Text = path; }
    }

    private async void Start(object? sender, RoutedEventArgs e)
    {
        if (Addresses.SelectedItem is not IPAddress address) { Status.Text = "Локальный адрес не найден"; return; }
        try
        {
            var session = new Receiver();
            receiver = session;
            using var generator = new QRCodeGenerator();
            using var data = generator.CreateQrCode(session.Invitation(address), QRCodeGenerator.ECCLevel.Q);
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
}
