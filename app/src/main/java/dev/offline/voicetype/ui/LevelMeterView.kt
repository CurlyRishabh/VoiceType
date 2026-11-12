package dev.offline.voicetype.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import dev.offline.voicetype.R

/** Live input level: a row of bars that rises with the voice and decays smoothly. */
class LevelMeterView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ContextCompat.getColor(context, R.color.brand) }
    private val history = FloatArray(BARS)
    private var head = 0

    var active: Boolean = false
        set(value) {
            field = value
            if (!value) history.fill(0f)
            paint.color = ContextCompat.getColor(context, if (value) R.color.recording else R.color.brand)
            invalidate()
        }

    fun setLevel(level: Float) {
        history[head] = level.coerceIn(0f, 1f)
        head = (head + 1) % BARS
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val barW = w / (BARS * 1.6f)
        val gap = barW * 0.6f
        val r = barW / 2
        for (i in 0 until BARS) {
            val v = history[(head + i) % BARS]
            val bh = maxOf(barW, v * h)
            val x = i * (barW + gap) + gap / 2
            val top = (h - bh) / 2
            canvas.drawRoundRect(x, top, x + barW, top + bh, r, r, paint)
        }
    }

    private companion object {
        const val BARS = 32
    }
}
