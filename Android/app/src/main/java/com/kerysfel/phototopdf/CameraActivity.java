package com.kerysfel.phototopdf;

import android.Manifest;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.*;
import androidx.activity.ComponentActivity;
import androidx.camera.core.*;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.content.ContextCompat;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import com.google.common.util.concurrent.ListenableFuture;
import java.io.File;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;

public final class CameraActivity extends ComponentActivity {
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private PreviewView preview;
    private ImageCapture capture;
    private Button shutter;
    private TextView count;
    private PageStore store;
    private volatile boolean working;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        try { store = new PageStore(this); } catch (Exception e) { Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show(); finish(); return; }
        var layout = new android.widget.LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        ViewCompat.setOnApplyWindowInsetsListener(layout, (view, insets) -> {
            var bars = insets.getInsets(WindowInsetsCompat.Type.systemBars());
            view.setPadding(0, bars.top, 0, bars.bottom);
            return insets;
        });
        getWindow().getDecorView().setSystemUiVisibility(android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | android.view.View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        preview = new PreviewView(this); layout.addView(preview, new LinearLayout.LayoutParams(-1, 0, 1));
        count = new TextView(this); count.setGravity(Gravity.CENTER); count.setTextSize(18); refresh(); layout.addView(count);
        var row = new LinearLayout(this); shutter = new Button(this); shutter.setText("Снять страницу"); shutter.setOnClickListener(v -> take());
        Button done = new Button(this); done.setText("Готово"); done.setOnClickListener(v -> { if (!working) finish(); });
        row.addView(shutter, new LinearLayout.LayoutParams(0, -2, 1)); row.addView(done, new LinearLayout.LayoutParams(0, -2, 1)); layout.addView(row);
        setContentView(layout);
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera();
        else requestPermissions(new String[]{Manifest.permission.CAMERA}, 1);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == 1 && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) startCamera();
        else { Toast.makeText(this, "Для съёмки нужен доступ к камере.", Toast.LENGTH_LONG).show(); finish(); }
    }
    private void startCamera() {
        ListenableFuture<ProcessCameraProvider> future = ProcessCameraProvider.getInstance(this);
        future.addListener(() -> {
            try {
                ProcessCameraProvider provider = future.get();
                Preview view = new Preview.Builder().build(); view.setSurfaceProvider(preview.getSurfaceProvider());
                capture = new ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY).build();
                provider.unbindAll(); provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, view, capture);
            } catch (Exception e) { Toast.makeText(this, "Не удалось открыть камеру: " + e.getMessage(), Toast.LENGTH_LONG).show(); }
        }, ContextCompat.getMainExecutor(this));
    }
    private void take() {
        if (capture == null || working) return;
        working = true; shutter.setEnabled(false);
        File raw;
        try { raw = File.createTempFile("capture-", ".jpg", getCacheDir()); }
        catch (Exception e) { working = false; shutter.setEnabled(true); Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show(); return; }
        capture.takePicture(new ImageCapture.OutputFileOptions.Builder(raw).build(), worker, new ImageCapture.OnImageSavedCallback() {
            @Override public void onImageSaved(ImageCapture.OutputFileResults output) {
                String error = null;
                try { store.addFile(raw); } catch (Exception e) { error = e.getMessage(); }
                raw.delete(); String finalError = error;
                runOnUiThread(() -> { working = false; shutter.setEnabled(true); refresh(); if (finalError != null) Toast.makeText(CameraActivity.this, finalError, Toast.LENGTH_LONG).show(); });
            }
            @Override public void onError(ImageCaptureException error) {
                raw.delete(); runOnUiThread(() -> { working = false; shutter.setEnabled(true); Toast.makeText(CameraActivity.this, error.getMessage(), Toast.LENGTH_LONG).show(); });
            }
        });
    }
    private void refresh() { count.setText("Сохранено страниц: " + store.pages.size()); }
    @Override public void onBackPressed() { if (!working) super.onBackPressed(); }
    @Override protected void onDestroy() { worker.shutdown(); super.onDestroy(); }
}
