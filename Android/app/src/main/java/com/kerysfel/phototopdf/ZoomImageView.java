package com.kerysfel.phototopdf;

import android.content.Context;
import android.graphics.Matrix;
import android.graphics.drawable.Drawable;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.widget.ImageView;

final class ZoomImageView extends ImageView {
    private final Matrix transform = new Matrix();
    private final ScaleGestureDetector scaleGesture;
    private float zoom = 1, lastX, lastY;

    ZoomImageView(Context context) {
        super(context);
        setScaleType(ScaleType.MATRIX);
        scaleGesture = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScale(ScaleGestureDetector detector) {
                float next = Math.max(1, Math.min(5, zoom * detector.getScaleFactor()));
                float factor = next / zoom; zoom = next;
                transform.postScale(factor, factor, detector.getFocusX(), detector.getFocusY());
                setImageMatrix(transform);
                return true;
            }
        });
    }
    @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) { super.onSizeChanged(w,h,oldw,oldh); fit(); }
    @Override public void setImageDrawable(Drawable drawable) { super.setImageDrawable(drawable); fit(); }
    private void fit() {
        Drawable drawable = getDrawable();
        if (drawable == null || getWidth() == 0 || getHeight() == 0 || drawable.getIntrinsicWidth() <= 0 || drawable.getIntrinsicHeight() <= 0) return;
        float scale = Math.min((float)getWidth()/drawable.getIntrinsicWidth(), (float)getHeight()/drawable.getIntrinsicHeight());
        transform.reset(); transform.postScale(scale,scale);
        transform.postTranslate((getWidth()-drawable.getIntrinsicWidth()*scale)/2, (getHeight()-drawable.getIntrinsicHeight()*scale)/2);
        zoom = 1; setImageMatrix(transform);
    }
    @Override public boolean onTouchEvent(MotionEvent event) {
        scaleGesture.onTouchEvent(event);
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                getParent().requestDisallowInterceptTouchEvent(true); lastX=event.getX(); lastY=event.getY(); return true;
            case MotionEvent.ACTION_MOVE:
                if (!scaleGesture.isInProgress() && event.getPointerCount()==1 && zoom>1) {
                    transform.postTranslate(event.getX()-lastX,event.getY()-lastY); setImageMatrix(transform);
                }
                lastX=event.getX(); lastY=event.getY(); return true;
            case MotionEvent.ACTION_UP: performClick(); return true;
            default: return true;
        }
    }
    @Override public boolean performClick() { super.performClick(); return true; }
}
