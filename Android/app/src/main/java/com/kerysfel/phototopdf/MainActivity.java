package com.kerysfel.phototopdf;

import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.view.Gravity;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.ComponentActivity;
import androidx.core.content.FileProvider;

import com.google.zxing.integration.android.IntentIntegrator;
import com.google.zxing.integration.android.IntentResult;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends ComponentActivity {
    private static final int IMPORT = 101, CAMERA = 102;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private PageStore store;
    private LinearLayout content;
    private EditText title;
    private Spinner quality;
    private TextView status;
    private File pendingPdf;
    private boolean busy;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow()
                .getDecorView()
                .setSystemUiVisibility(
                        View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                                | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        try {
            store = new PageStore(this);
        } catch (Exception e) {
            new AlertDialog.Builder(this)
                    .setTitle("Не удалось открыть комплект")
                    .setMessage(e.getMessage())
                    .setPositiveButton("Закрыть", (d, w) -> finish())
                    .show();
            return;
        }
        if (state != null && state.getString("pending") != null)
            pendingPdf = new File(store.exportsDir, state.getString("pending"));
        showMain();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        if (pendingPdf != null) out.putString("pending", pendingPdf.getName());
    }

    private TextView text(String value, int size) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setPadding(8, 8, 8, 8);
        return view;
    }

    private Button button(String label, Runnable action) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setMinWidth(0);
        button.setMinimumWidth(0);
        button.setOnClickListener(
                view -> {
                    if (!busy) action.run();
                });
        return button;
    }

    private void showScreen(String heading) {
        ScrollView scroll = new ScrollView(this);
        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int top = (int) (36 * getResources().getDisplayMetrics().density);
        content.setPadding(20, top, 20, 30);
        scroll.addView(content);
        setContentView(scroll);
        content.addView(text(heading, 24));
    }

    private void showMain() {
        showScreen("Фото → PDF");
        title = new EditText(this);
        title.setSingleLine();
        title.setText(store.title);
        title.setHint("Название комплекта");
        content.addView(title);
        content.addView(text(store.pages.size() + " страниц в общем PDF", 18));
        LinearLayout actions = new LinearLayout(this);
        actions.addView(
                button("Снимать", this::openCamera), new LinearLayout.LayoutParams(0, -2, 1));
        actions.addView(
                button("Из фото", this::choosePhotos), new LinearLayout.LayoutParams(0, -2, 1));
        content.addView(actions);
        quality = new Spinner(this);
        quality.setAdapter(
                new ArrayAdapter<>(
                        this,
                        android.R.layout.simple_spinner_dropdown_item,
                        new String[] {"Качество 100%", "Качество 75%", "Качество 50%"}));
        content.addView(quality);
        content.addView(button("Собрать PDF и поделиться", () -> export(false)));
        content.addView(button("Отправить на компьютер", () -> export(true)));
        content.addView(button("История проектов", this::showHistory));
        content.addView(button("Очистить снимки", this::confirmClear));
        status = text("PDF: A4, одна фотография на страницу. Снимки хранятся на устройстве.", 14);
        content.addView(status);
        for (int i = 0; i < store.pages.size(); i++) {
            content.addView(pageRow(i));
        }
    }

    private void openCamera() {
        saveTitle(() -> startActivityForResult(new Intent(this, CameraActivity.class), CAMERA));
    }

    private void choosePhotos() {
        saveTitle(
                () -> {
                    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                    intent.setType("image/*");
                    intent.addCategory(Intent.CATEGORY_OPENABLE);
                    intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                    startActivityForResult(intent, IMPORT);
                });
    }

    private void confirmClear() {
        new AlertDialog.Builder(this)
                .setTitle("Очистить текущий комплект?")
                .setMessage("Снимки будут удалены. PDF в истории останутся.")
                .setNegativeButton("Отмена", null)
                .setPositiveButton(
                        "Очистить",
                        (dialog, which) ->
                                runJob(
                                        "Очистка…",
                                        () -> {
                                            store.clear();
                                            return null;
                                        },
                                        ignored -> showMain()))
                .show();
    }

    private LinearLayout pageRow(int index) {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        Button page =
                button(
                        "Страница " + (index + 1),
                        () -> showImage(new File(store.pagesDir, store.pages.get(index))));
        row.addView(page, new LinearLayout.LayoutParams(0, -2, 1));
        Button up = button("↑", () -> swap(index, index - 1));
        up.setEnabled(index > 0);
        row.addView(up);
        Button down = button("↓", () -> swap(index, index + 1));
        down.setEnabled(index + 1 < store.pages.size());
        row.addView(down);
        row.addView(button("✕", () -> confirmRemovePage(index)));
        return row;
    }

    private void confirmRemovePage(int index) {
        new AlertDialog.Builder(this)
                .setMessage("Удалить страницу " + (index + 1) + "?")
                .setNegativeButton("Отмена", null)
                .setPositiveButton(
                        "Удалить",
                        (dialog, which) ->
                                runJob(
                                        "Удаление…",
                                        () -> {
                                            store.remove(index);
                                            return null;
                                        },
                                        ignored -> showMain()))
                .show();
    }

    private void saveTitle(Runnable after) {
        String name = title.getText().toString();
        try {
            store.rename(name);
            after.run();
        } catch (Exception e) {
            error(e);
        }
    }

    private void swap(int from, int to) {
        saveTitle(
                () ->
                        runJob(
                                "Перестановка…",
                                () -> {
                                    store.move(from, to);
                                    return null;
                                },
                                ignored -> showMain()));
    }

    private void export(boolean computer) {
        if (store.pages.isEmpty()) {
            toast("Сначала добавьте фотографии.");
            return;
        }
        int selectedQuality = new int[] {100, 75, 50}[quality.getSelectedItemPosition()];
        saveTitle(
                () ->
                        runJob(
                                "Сборка PDF…",
                                () -> store.export(selectedQuality, this::showExportProgress),
                                file -> {
                                    if (computer) scan(file);
                                    else share(file);
                                }));
    }

    private void showExportProgress(int done, int total) {
        runOnUiThread(
                () -> {
                    if (status != null && busy)
                        status.setText("Сборка PDF: " + done + " / " + total);
                });
    }

    private void share(File file) {
        Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", file);
        Intent intent = new Intent(Intent.ACTION_SEND);
        intent.setType("application/pdf");
        intent.putExtra(Intent.EXTRA_STREAM, uri);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(Intent.createChooser(intent, "Поделиться PDF"));
        // Android's chooser does not reliably confirm delivery. Keep the current set.
    }

    private void scan(File file) {
        pendingPdf = file;
        new IntentIntegrator(this)
                .setCaptureActivity(QRScannerActivity.class)
                .setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
                .setPrompt("Отсканируйте QR-код на своём компьютере")
                .setBeepEnabled(false)
                .setOrientationLocked(true)
                .initiateScan();
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        IntentResult qr = IntentIntegrator.parseActivityResult(request, result, data);
        if (qr != null) {
            if (qr.getContents() != null && pendingPdf != null) {
                File file = pendingPdf;
                pendingPdf = null;
                runJob(
                        "Подключение. Подтвердите получение на компьютере…",
                        () -> {
                            ComputerTransfer.send(
                                    file,
                                    qr.getContents(),
                                    (sent, total) ->
                                            runOnUiThread(
                                                    () -> {
                                                        if (status != null)
                                                            status.setText(
                                                                    "Передача: "
                                                                            + sent * 100 / total
                                                                            + "%");
                                                    }));
                            return null;
                        },
                        ignored ->
                                new AlertDialog.Builder(this)
                                        .setMessage("Компьютер подтвердил сохранение PDF.")
                                        .setPositiveButton("OK", null)
                                        .show());
            }
            return;
        }
        if (request == CAMERA) {
            try {
                store = new PageStore(this);
                showMain();
            } catch (Exception e) {
                error(e);
            }
            return;
        }
        if (request == IMPORT && result == RESULT_OK && data != null) {
            ArrayList<Uri> uris = new ArrayList<>();
            if (data.getClipData() != null)
                for (int i = 0; i < data.getClipData().getItemCount(); i++)
                    uris.add(data.getClipData().getItemAt(i).getUri());
            else if (data.getData() != null) uris.add(data.getData());
            runJob(
                    "Импорт фотографий…",
                    () -> {
                        for (Uri uri : uris) store.addUri(uri);
                        return null;
                    },
                    ignored -> showMain());
        }
    }

    private void showHistory() {
        showScreen("История проектов");
        content.addView(button("Назад", this::showMain));
        File[] files =
                store.exportsDir.listFiles(
                        (dir, name) -> name.toLowerCase(Locale.ROOT).endsWith(".pdf"));
        if (files == null || files.length == 0) {
            content.addView(text("Пока нет собранных PDF", 18));
            return;
        }
        Arrays.sort(files, (a, b) -> Long.compare(b.lastModified(), a.lastModified()));
        for (File file : files) {
            String date =
                    android.text.format.DateFormat.format("dd.MM.yyyy HH:mm", file.lastModified())
                            .toString();
            TextView description = text(file.getName() + "\n" + date, 16);
            content.addView(description);
            worker.execute(
                    () -> {
                        try (ParcelFileDescriptor fd =
                                        ParcelFileDescriptor.open(
                                                file, ParcelFileDescriptor.MODE_READ_ONLY);
                                PdfRenderer renderer = new PdfRenderer(fd)) {
                            int count = renderer.getPageCount();
                            runOnUiThread(
                                    () -> {
                                        if (description.isAttachedToWindow())
                                            description.setText(
                                                    file.getName()
                                                            + "\n"
                                                            + count
                                                            + " стр. · "
                                                            + date);
                                    });
                        } catch (Exception ignored) {
                        }
                    });
            LinearLayout row = new LinearLayout(this);
            for (Button action :
                    new Button[] {
                        button("Открыть", () -> showPdf(file, 0)),
                        button("Поделиться", () -> share(file)),
                        button("На компьютер", () -> scan(file))
                    }) {
                action.setTextSize(12);
                row.addView(action, new LinearLayout.LayoutParams(0, -2, 1));
            }
            content.addView(row);
            content.addView(
                    button(
                            "Удалить PDF",
                            () ->
                                    new AlertDialog.Builder(this)
                                            .setTitle("Удалить проект?")
                                            .setMessage(
                                                    "PDF будет удалён из истории и памяти"
                                                        + " приложения. Другие копии останутся.")
                                            .setNegativeButton("Отмена", null)
                                            .setPositiveButton(
                                                    "Удалить",
                                                    (d, w) -> {
                                                        if (!file.delete())
                                                            toast("Не удалось удалить PDF.");
                                                        showHistory();
                                                    })
                                            .show()));
        }
        status = text("", 14);
        content.addView(status);
    }

    private void showPdf(File file, int index) {
        showScreen("Просмотр PDF");
        content.addView(button("К истории", this::showHistory));
        ZoomImageView view = new ZoomImageView(this);
        content.addView(
                view,
                new LinearLayout.LayoutParams(
                        -1, (int) (420 * getResources().getDisplayMetrics().density)));
        LinearLayout row = new LinearLayout(this);
        Button prev = button("←", () -> showPdf(file, index - 1)),
                next = button("→", () -> showPdf(file, index + 1));
        row.addView(prev);
        TextView label = text("", 16);
        row.addView(label);
        row.addView(next);
        content.addView(row);
        runJob(
                "Открытие…",
                () -> renderPage(file, index),
                result -> {
                    view.setImageBitmap(result.bitmap);
                    label.setText((index + 1) + " / " + result.pageCount);
                    prev.setEnabled(index > 0);
                    next.setEnabled(index + 1 < result.pageCount);
                });
    }

    private RenderedPage renderPage(File file, int index) throws IOException {
        try (ParcelFileDescriptor descriptor =
                        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
                PdfRenderer renderer = new PdfRenderer(descriptor)) {
            int pageCount = renderer.getPageCount();
            if (index < 0 || index >= pageCount) throw new IOException("Страница недоступна.");
            try (PdfRenderer.Page page = renderer.openPage(index)) {
                int width = 1200;
                int height = Math.max(1, (int) ((long) page.getHeight() * width / page.getWidth()));
                Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                bitmap.eraseColor(Color.WHITE);
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                return new RenderedPage(bitmap, pageCount);
            }
        }
    }

    private void showImage(File file) {
        showScreen("Просмотр страницы");
        content.addView(button("Назад", this::showMain));
        ZoomImageView image = new ZoomImageView(this);
        content.addView(
                image,
                new LinearLayout.LayoutParams(
                        -1, (int) (420 * getResources().getDisplayMetrics().density)));
        runJob("Открытие…", () -> PageStore.decode(file, 1800), image::setImageBitmap);
    }

    private static final class RenderedPage {
        final Bitmap bitmap;
        final int pageCount;

        RenderedPage(Bitmap bitmap, int pageCount) {
            this.bitmap = bitmap;
            this.pageCount = pageCount;
        }
    }

    private interface Job<T> {
        T run() throws Exception;
    }

    private interface Done<T> {
        void accept(T value);
    }

    private <T> void runJob(String message, Job<T> job, Done<T> done) {
        if (busy) return;
        busy = true;
        if (status != null) status.setText(message);
        worker.execute(
                () -> {
                    try {
                        T value = job.run();
                        runOnUiThread(
                                () -> {
                                    busy = false;
                                    if (!isFinishing() && !isDestroyed()) {
                                        if (status != null) status.setText("");
                                        done.accept(value);
                                    }
                                });
                    } catch (Exception e) {
                        runOnUiThread(
                                () -> {
                                    busy = false;
                                    if (!isFinishing() && !isDestroyed()) {
                                        if (status != null) status.setText("");
                                        error(e);
                                    }
                                });
                    }
                });
    }

    private void error(Exception e) {
        new AlertDialog.Builder(this)
                .setTitle("Не удалось выполнить действие")
                .setMessage(e.getLocalizedMessage())
                .setPositiveButton("OK", null)
                .show();
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_LONG).show();
    }

    @Override
    protected void onPause() {
        if (!busy && store != null && title != null && title.isAttachedToWindow()) {
            try {
                store.rename(title.getText().toString());
            } catch (Exception e) {
                toast("Не удалось сохранить название.");
            }
        }
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        worker.shutdown();
        super.onDestroy();
    }
}
