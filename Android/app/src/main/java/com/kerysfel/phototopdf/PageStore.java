package com.kerysfel.phototopdf;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.net.Uri;
import android.util.AtomicFile;
import androidx.exifinterface.media.ExifInterface;
import com.tom_roush.pdfbox.io.MemoryUsageSetting;
import com.tom_roush.pdfbox.pdmodel.PDDocument;
import com.tom_roush.pdfbox.pdmodel.PDPage;
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream;
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle;
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory;
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject;
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.util.*;

final class PageStore {
    final Context context;
    final File pagesDir, exportsDir;
    final ArrayList<String> pages = new ArrayList<>();
    String title = "Новый комплект";
    private final AtomicFile manifest;

    PageStore(Context context) throws Exception {
        this.context = context.getApplicationContext();
        pagesDir = new File(context.getFilesDir(), "Pages");
        exportsDir = new File(context.getFilesDir(), "Exports");
        if ((!pagesDir.exists() && !pagesDir.mkdirs()) || (!exportsDir.exists() && !exportsDir.mkdirs())) throw new IOException("Не удалось открыть папки приложения.");
        manifest = new AtomicFile(new File(context.getFilesDir(), "session.json"));
        if (manifest.getBaseFile().exists()) {
            try (FileInputStream in = manifest.openRead()) {
                ByteArrayOutputStream bytes = new ByteArrayOutputStream(); copy(in, bytes);
                JSONObject obj = new JSONObject(new String(bytes.toByteArray(), java.nio.charset.StandardCharsets.UTF_8));
                title = obj.optString("title", title);
                JSONArray list = obj.getJSONArray("pages");
                for (int i = 0; i < list.length(); i++) {
                    String name = list.getString(i);
                    if (!name.matches("[a-f0-9-]+\\.jpg")) throw new IOException("Повреждён список страниц.");
                    File actual = new File(pagesDir, name), deleted = new File(pagesDir, name + ".deleted");
                    if (!actual.exists() && deleted.exists() && !deleted.renameTo(actual)) throw new IOException("Не удалось восстановить страницу.");
                    if (!actual.exists()) throw new IOException("Не найдена страница " + (i + 1));
                    pages.add(name);
                }
            }
        }
        File[] entries = pagesDir.listFiles();
        if (entries != null) {
            Arrays.sort(entries, Comparator.comparing(File::getName));
            for (File file : entries) {
                String name = file.getName();
                if (name.matches("[a-f0-9-]+\\.jpg") && !pages.contains(name)) pages.add(name);
                else if (name.matches("[a-f0-9-]+\\.jpg\\.deleted") && !pages.contains(name.substring(0, name.length() - 8))) file.delete();
            }
            persist();
        }
        PDFBoxResourceLoader.init(this.context);
    }

    private static void copy(InputStream in, OutputStream out) throws IOException { byte[] buffer = new byte[65536]; int n; while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n); }

    synchronized void persist() throws Exception {
        JSONObject obj = new JSONObject(); obj.put("title", title); obj.put("pages", new JSONArray(pages));
        FileOutputStream out = manifest.startWrite();
        try { out.write(obj.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)); manifest.finishWrite(out); }
        catch (Exception e) { manifest.failWrite(out); throw e; }
    }

    synchronized void rename(String value) throws Exception {
        String old = title; title = value;
        try { persist(); } catch (Exception e) { title = old; throw e; }
    }

    synchronized void addUri(Uri uri) throws Exception {
        File raw = File.createTempFile("import-", ".image", context.getCacheDir());
        try (InputStream in = context.getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(raw)) {
            if (in == null) throw new IOException("Не удалось открыть изображение.");
            copy(in, out);
        } catch (Exception e) { raw.delete(); throw e; }
        try { addFile(raw); } finally { raw.delete(); }
    }

    synchronized void addFile(File source) throws Exception {
        Bitmap bitmap = decode(source, 3000);
        String name = UUID.randomUUID() + ".jpg";
        File target = new File(pagesDir, name), part = new File(pagesDir, name + ".part");
        try {
            try (FileOutputStream out = new FileOutputStream(part)) {
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out)) throw new IOException("Не удалось сохранить снимок.");
                out.getFD().sync();
            }
            if (!part.renameTo(target)) throw new IOException("Не удалось сохранить снимок.");
            pages.add(name);
            try { persist(); } catch (Exception e) { pages.remove(pages.size() - 1); target.delete(); throw e; }
        } finally { bitmap.recycle(); part.delete(); }
    }

    static Bitmap decode(File source, int maxSide) throws Exception {
        BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(source.getPath(), bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw new IOException("Не удалось прочитать изображение.");
        BitmapFactory.Options opts = new BitmapFactory.Options(); opts.inSampleSize = 1;
        while (Math.max(bounds.outWidth, bounds.outHeight) / (opts.inSampleSize * 2) >= maxSide) opts.inSampleSize *= 2;
        Bitmap original = BitmapFactory.decodeFile(source.getPath(), opts);
        if (original == null) throw new IOException("Не удалось прочитать изображение.");
        int orientation = new ExifInterface(source).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
        Matrix matrix = new Matrix();
        switch (orientation) {
            case ExifInterface.ORIENTATION_ROTATE_90: matrix.postRotate(90); break;
            case ExifInterface.ORIENTATION_ROTATE_180: matrix.postRotate(180); break;
            case ExifInterface.ORIENTATION_ROTATE_270: matrix.postRotate(270); break;
            case ExifInterface.ORIENTATION_FLIP_HORIZONTAL: matrix.postScale(-1, 1); break;
            case ExifInterface.ORIENTATION_FLIP_VERTICAL: matrix.postScale(1, -1); break;
            case ExifInterface.ORIENTATION_TRANSPOSE: matrix.postScale(-1, 1); matrix.postRotate(270); break;
            case ExifInterface.ORIENTATION_TRANSVERSE: matrix.postScale(-1, 1); matrix.postRotate(90); break;
        }
        float scale = Math.min(1f, (float) maxSide / Math.max(original.getWidth(), original.getHeight()));
        matrix.postScale(scale, scale);
        Bitmap result = Bitmap.createBitmap(original, 0, 0, original.getWidth(), original.getHeight(), matrix, true);
        if (result != original) original.recycle();
        return result;
    }

    synchronized void remove(int index) throws Exception {
        String name = pages.get(index); File original = new File(pagesDir, name), trash = new File(pagesDir, name + ".deleted");
        if (!original.renameTo(trash)) throw new IOException("Не удалось удалить страницу.");
        pages.remove(index);
        try { persist(); } catch (Exception e) { pages.add(index, name); trash.renameTo(original); throw e; }
        trash.delete();
    }
    synchronized void move(int from, int to) throws Exception {
        Collections.swap(pages, from, to);
        try { persist(); } catch (Exception e) { Collections.swap(pages, from, to); throw e; }
    }
    synchronized void clear() throws Exception {
        ArrayList<String> old = new ArrayList<>(pages); String oldTitle = title;
        ArrayList<String> renamed = new ArrayList<>();
        try {
            for (String name : old) {
                if (!new File(pagesDir, name).renameTo(new File(pagesDir, name + ".deleted"))) throw new IOException("Не удалось очистить снимки.");
                renamed.add(name);
            }
            pages.clear(); title = "Новый комплект"; persist();
        } catch (Exception e) {
            pages.clear(); pages.addAll(old); title = oldTitle;
            for (String name : renamed) new File(pagesDir, name + ".deleted").renameTo(new File(pagesDir, name));
            throw e;
        }
        for (String name : old) new File(pagesDir, name + ".deleted").delete();
    }
    synchronized File export(int quality) throws Exception { return export(quality, (done, total) -> {}); }
    synchronized File export(int quality, ExportProgress progress) throws Exception {
        if (pages.isEmpty()) throw new IOException("Сначала добавьте фотографии.");
        String name = title.trim().replaceAll("[^\\p{L}\\p{N} _-]", "");
        if (name.isEmpty()) name = "Комплект";
        if (name.length() > 70) name = name.substring(0,70);
        File result = new File(exportsDir, name + " — " + System.currentTimeMillis() + ".pdf");
        File part = new File(exportsDir, result.getName() + ".part");
        try (PDDocument doc = new PDDocument(MemoryUsageSetting.setupTempFileOnly().setTempDir(context.getCacheDir()))) {
            int completed = 0;
            for (String page : pages) {
                File image = new File(pagesDir, page);
                PDImageXObject embedded;
                if (quality == 100) {
                    try (InputStream in = new FileInputStream(image)) { embedded = JPEGFactory.createFromStream(doc, in); }
                } else {
                    Bitmap bitmap = decode(image, quality == 75 ? 2250 : 1500);
                    try (ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, bytes)) throw new IOException("Ошибка JPEG.");
                        embedded = JPEGFactory.createFromStream(doc, new ByteArrayInputStream(bytes.toByteArray()));
                    } finally { bitmap.recycle(); }
                }
                PDPage sheet = new PDPage(PDRectangle.A4); doc.addPage(sheet);
                float width = PDRectangle.A4.getWidth(), height = PDRectangle.A4.getHeight();
                float scale = Math.min(width / embedded.getWidth(), height / embedded.getHeight());
                float w = embedded.getWidth() * scale, h = embedded.getHeight() * scale;
                try (PDPageContentStream content = new PDPageContentStream(doc, sheet)) { content.drawImage(embedded, (width-w)/2, (height-h)/2, w, h); }
                progress.update(++completed, pages.size());
            }
            doc.save(part);
        } catch (Exception e) { part.delete(); throw e; }
        if (!part.renameTo(result)) { part.delete(); throw new IOException("Не удалось сохранить PDF."); }
        return result;
    }
    interface ExportProgress { void update(int done, int total); }
}
