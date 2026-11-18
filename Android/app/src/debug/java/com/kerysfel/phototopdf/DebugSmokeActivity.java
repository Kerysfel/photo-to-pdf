package com.kerysfel.phototopdf;

import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

public final class DebugSmokeActivity extends Activity {
    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        new Thread(
                        () -> {
                            File result = new File(getFilesDir(), "smoke-result.txt");
                            try {
                                File isolated =
                                        new File(getCacheDir(), "smoke-" + System.nanoTime());
                                if (!isolated.mkdirs()) throw new IOException("test directory");
                                Context context =
                                        new ContextWrapper(this) {
                                            @Override
                                            public Context getApplicationContext() {
                                                return this;
                                            }

                                            @Override
                                            public File getFilesDir() {
                                                return isolated;
                                            }
                                        };
                                PageStore store = new PageStore(context);
                                Bitmap image =
                                        Bitmap.createBitmap(120, 180, Bitmap.Config.ARGB_8888);
                                image.eraseColor(Color.WHITE);
                                File raw = new File(isolated, "sample.jpg");
                                try (FileOutputStream out = new FileOutputStream(raw)) {
                                    image.compress(Bitmap.CompressFormat.JPEG, 82, out);
                                }
                                image.recycle();
                                for (int i = 0; i < 240; i++) store.addFile(raw);
                                store.rename("Тест");
                                store.move(0, 1);
                                store.remove(0);
                                store = new PageStore(context);
                                if (store.pages.size() != 239 || !store.title.equals("Тест"))
                                    throw new IOException("restore mismatch");
                                for (int quality : new int[] {100, 75, 50}) {
                                    File pdf = store.export(quality);
                                    try (ParcelFileDescriptor fd =
                                                    ParcelFileDescriptor.open(
                                                            pdf,
                                                            ParcelFileDescriptor.MODE_READ_ONLY);
                                            PdfRenderer renderer = new PdfRenderer(fd)) {
                                        if (renderer.getPageCount() != 239)
                                            throw new IOException("PDF page count");
                                    }
                                }
                                store.clear();
                                PageStore reopened = new PageStore(context);
                                if (!reopened.pages.isEmpty()
                                        || reopened.exportsDir.listFiles(
                                                                (d, n) -> n.endsWith(".pdf"))
                                                        .length
                                                != 3)
                                    throw new IOException("clear/history mismatch");
                                String invite = getIntent().getStringExtra("invite");
                                String encoded = getIntent().getStringExtra("invite64");
                                if (encoded != null)
                                    invite =
                                            new String(
                                                    android.util.Base64.decode(
                                                            encoded, android.util.Base64.DEFAULT),
                                                    StandardCharsets.UTF_8);
                                if (invite != null) {
                                    File pdf =
                                            reopened.exportsDir
                                                    .listFiles((d, n) -> n.endsWith(".pdf"))[0];
                                    if (getIntent().getBooleanExtra("badpin", false)) {
                                        org.json.JSONObject modified =
                                                new org.json.JSONObject(invite);
                                        modified.put(
                                                "certificateSha256",
                                                "0000000000000000000000000000000000000000000000000000000000000000");
                                        boolean refused = false;
                                        try {
                                            ComputerTransfer.send(
                                                    pdf, modified.toString(), (sent, total) -> {});
                                        } catch (javax.net.ssl.SSLHandshakeException expected) {
                                            refused = true;
                                        }
                                        if (!refused)
                                            throw new IOException("Wrong certificate accepted");
                                    } else ComputerTransfer.send(pdf, invite, (sent, total) -> {});
                                }
                                try (FileOutputStream out = new FileOutputStream(result)) {
                                    out.write(
                                            (invite == null
                                                            ? "PASS 240 images, restart, 239 pages"
                                                                    + " x 3 qualities, clear,"
                                                                    + " retained history"
                                                            : "PASS 240 images, PDF and TLS"
                                                                    + " transfer")
                                                    .getBytes(StandardCharsets.UTF_8));
                                }
                                deleteTree(isolated);
                            } catch (Throwable e) {
                                try (FileOutputStream out = new FileOutputStream(result)) {
                                    out.write(
                                            ("FAIL " + android.util.Log.getStackTraceString(e))
                                                    .getBytes(StandardCharsets.UTF_8));
                                } catch (IOException ignored) {
                                }
                            } finally {
                                runOnUiThread(this::finish);
                            }
                        })
                .start();
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }
}
