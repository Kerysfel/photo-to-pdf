package com.kerysfel.phototopdf;

import android.util.Base64;

import org.json.JSONObject;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

final class ComputerTransfer {
    interface Progress {
        void update(long sent, long total);
    }

    static void send(File file, String qr, Progress progress) throws Exception {
        if (qr == null || qr.length() > 2048) throw new IOException("Неверный QR-код.");
        JSONObject invite = new JSONObject(qr);
        String host = invite.getString("host"),
                pin = invite.getString("certificateSha256"),
                secret = invite.getString("secret");
        int port = invite.getInt("port");
        if (invite.getInt("version") != 1
                || port < 1
                || port > 65535
                || !localIp(host)
                || !pin.matches("[a-f0-9]{64}")
                || Base64.decode(secret, Base64.DEFAULT).length != 32)
            throw new IOException("Неверный QR-код приёмника или сетевой адрес.");
        long size = file.length();
        if (size <= 0 || size > 2147483648L)
            throw new IOException("Размер PDF должен быть от 1 байта до 2 ГиБ.");
        byte[] expected = hex(pin);
        X509TrustManager trust =
                new X509TrustManager() {
                    public void checkClientTrusted(X509Certificate[] chain, String auth)
                            throws CertificateException {
                        throw new CertificateException("Not a client");
                    }

                    public void checkServerTrusted(X509Certificate[] chain, String auth)
                            throws CertificateException {
                        try {
                            if (chain == null
                                    || chain.length == 0
                                    || !MessageDigest.isEqual(
                                            expected,
                                            MessageDigest.getInstance("SHA-256")
                                                    .digest(chain[0].getEncoded())))
                                throw new CertificateException(
                                        "Сертификат компьютера не совпадает с QR-кодом.");
                        } catch (GeneralSecurityException e) {
                            throw new CertificateException(e);
                        }
                    }

                    public X509Certificate[] getAcceptedIssuers() {
                        return new X509Certificate[0];
                    }
                };
        SSLContext tls = SSLContext.getInstance("TLS");
        tls.init(null, new TrustManager[] {trust}, new SecureRandom());
        try (SSLSocket socket = (SSLSocket) tls.getSocketFactory().createSocket()) {
            socket.connect(new InetSocketAddress(host, port), 15000);
            socket.setSoTimeout(600000);
            socket.setEnabledProtocols(new String[] {"TLSv1.2"});
            socket.startHandshake();
            DataInputStream in = new DataInputStream(socket.getInputStream());
            DataOutputStream out = new DataOutputStream(socket.getOutputStream());
            JSONObject offer = new JSONObject();
            offer.put("secret", secret);
            offer.put("name", file.getName());
            offer.put("size", size);
            write(out, offer);
            if (!"accepted".equals(read(in).optString("status")))
                throw new IOException("Получение отклонено на компьютере.");
            MessageDigest hash = MessageDigest.getInstance("SHA-256");
            long sent = 0;
            try (InputStream input = new FileInputStream(file)) {
                byte[] buffer = new byte[65536];
                int n;
                while (sent < size
                        && (n = input.read(buffer, 0, (int) Math.min(buffer.length, size - sent)))
                                != -1) {
                    out.write(buffer, 0, n);
                    hash.update(buffer, 0, n);
                    sent += n;
                    progress.update(sent, size);
                }
            }
            if (sent != size || file.length() != size)
                throw new IOException("Файл изменился во время отправки.");
            StringBuilder digest = new StringBuilder();
            for (byte b : hash.digest())
                digest.append(String.format(java.util.Locale.ROOT, "%02x", b & 0xff));
            JSONObject trailer = new JSONObject();
            trailer.put("sha256", digest.toString());
            write(out, trailer);
            if (!"saved".equals(read(in).optString("status")))
                throw new IOException("Нет подтверждения сохранения.");
        }
    }

    private static void write(DataOutputStream out, JSONObject data) throws Exception {
        byte[] bytes = data.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
        if (bytes.length > 4096) throw new IOException("Слишком длинное сообщение.");
        out.writeInt(bytes.length);
        out.write(bytes);
        out.flush();
    }

    private static JSONObject read(DataInputStream in) throws Exception {
        int length = in.readInt();
        if (length <= 0 || length > 4096) throw new IOException("Некорректный ответ компьютера.");
        byte[] bytes = new byte[length];
        in.readFully(bytes);
        return new JSONObject(new String(bytes, java.nio.charset.StandardCharsets.UTF_8));
    }

    private static boolean localIp(String host) {
        String[] parts = host.split("\\.", -1);
        if (parts.length != 4) return false;
        int[] nums = new int[4];
        try {
            for (int i = 0; i < 4; i++) {
                if (!parts[i].matches("0|[1-9][0-9]{0,2}")) return false;
                nums[i] = Integer.parseInt(parts[i]);
                if (nums[i] > 255) return false;
            }
        } catch (NumberFormatException e) {
            return false;
        }
        return nums[0] == 10
                || (nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31)
                || (nums[0] == 192 && nums[1] == 168)
                || (nums[0] == 169 && nums[1] == 254);
    }

    private static byte[] hex(String text) {
        byte[] result = new byte[text.length() / 2];
        for (int i = 0; i < result.length; i++)
            result[i] = (byte) Integer.parseInt(text.substring(i * 2, i * 2 + 2), 16);
        return result;
    }
}
