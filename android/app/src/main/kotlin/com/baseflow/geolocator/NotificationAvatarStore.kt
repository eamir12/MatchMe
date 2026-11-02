package com.baseflow.geolocator

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/**
 * Avatars the notification tray card draws with setLargeIcon.
 *
 * The app's real image cache (OfflineImageCache) is an encrypted Hive box no
 * native renderer can open, so the one picture a card needs is mirrored here as
 * a small plain JPEG by way of the matchme/background_service channel. Nothing
 * else lives in this directory: no message text, and not even a readable user or
 * conversation id, because the file name is a hash of it.
 *
 * It sits under noBackupFilesDir, which Android never backs up by construction,
 * and is excluded a second time in both backup_rules.xml and
 * data_extraction_rules.xml so a future change in either cannot quietly start
 * shipping faces off the device.
 *
 * Dart cards (meet-up, expiry, location) read this directory themselves rather
 * than asking for a path: the FCM background isolate has no handler on our
 * channel, so `notification_avatars` under `no_backup` is a contract between
 * [NotificationAvatarStore.dir] and `NotificationAvatarService._mirrorDir`, and
 * changing either name silently takes the face off those cards.
 */
object NotificationAvatarStore {

    /**
     * Tray largeIcon slots render around 72-96dp; 128px covers a 2x screen and
     * nothing in a notification is drawn bigger.
     */
    private const val MAX_EDGE_PX = 128
    private const val MAX_FILE_BYTES = 32 * 1024

    /** A long chat list must not turn the mirror into an unbounded photo dump. */
    private const val MAX_ENTRIES = 64

    private fun dir(context: Context): File =
        File(context.noBackupFilesDir, "notification_avatars")

    private fun hash(raw: String): String = try {
        MessageDigest.getInstance("SHA-256")
            .digest(raw.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    } catch (_: Exception) {
        ""
    }

    /**
     * `<conversation hash>-<source hash>.jpg` — a changed avatar is a different
     * file, so the old one can be dropped, and neither id is readable.
     */
    private fun fileNameFor(matchId: String, cacheKey: String): String {
        val m = hash(matchId)
        if (m.isEmpty()) return ""
        return "$m-${hash(cacheKey).take(16)}.jpg"
    }

    /** True when this exact avatar is already on disk. */
    fun isMirrored(context: Context, matchId: String, cacheKey: String): Boolean {
        val name = fileNameFor(matchId, cacheKey)
        if (name.isEmpty()) return false
        return try {
            File(dir(context), name).exists()
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Writes [bytes] — any image size the app already holds — down to tray size.
     * Never throws: an avatar is a decoration, and a card without one is still a
     * correct card.
     */
    fun mirror(context: Context, matchId: String, cacheKey: String, bytes: ByteArray): Boolean {
        if (matchId.isBlank() || bytes.isEmpty()) return false
        val name = fileNameFor(matchId, cacheKey)
        if (name.isEmpty()) return false
        val directory = try {
            dir(context).apply { if (!exists()) mkdirs() }
        } catch (_: Exception) {
            return false
        }
        val target = File(directory, name)
        if (target.exists()) return true

        val encoded = try {
            scaleToAvatar(bytes)
        } catch (_: Exception) {
            null
        } ?: return false

        return try {
            // Written aside and renamed, so a card built while this runs can
            // only see the old avatar or the new one, never half of either.
            val staging = File(directory, "$name.tmp")
            staging.writeBytes(encoded)
            if (!staging.renameTo(target)) {
                staging.delete()
                target.writeBytes(encoded)
            }
            // Replace any older avatar of this same conversation.
            val prefix = "${hash(matchId)}-"
            directory.listFiles()?.forEach { old ->
                if (old.name != name && old.name.startsWith(prefix)) old.delete()
            }
            pruneToEntryCap(directory)
            true
        } catch (_: Exception) {
            try {
                target.delete()
            } catch (_: Exception) {
            }
            false
        }
    }

    fun bitmapFor(context: Context, matchId: String): Bitmap? {
        val path = pathFor(context, matchId) ?: return null
        return try {
            BitmapFactory.decodeFile(path)
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Absolute path of this conversation's mirrored face, or null when it has
     * none.
     */
    private fun pathFor(context: Context, matchId: String): String? {
        if (matchId.isBlank()) return null
        val prefix = hash(matchId)
        if (prefix.isEmpty()) return null
        return try {
            dir(context).listFiles()?.firstOrNull {
                it.name.startsWith("$prefix-") && it.name.endsWith(".jpg")
            }?.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    fun evict(context: Context, matchId: String) {
        if (matchId.isBlank()) return
        val prefix = hash(matchId)
        if (prefix.isEmpty()) return
        try {
            dir(context).listFiles()?.forEach { f ->
                if (f.name.startsWith("$prefix-")) f.delete()
            }
        } catch (_: Exception) {
        }
    }

    fun clearAll(context: Context) {
        try {
            dir(context).listFiles()?.forEach { it.delete() }
        } catch (_: Exception) {
        }
    }

    /**
     * Decodes at reduced size first (inSampleSize skips the full-size
     * allocation), center-crops to a square because the tray slot is square,
     * then re-encodes at descending quality until the file fits the budget.
     */
    private fun scaleToAvatar(bytes: ByteArray): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) return null

        var sample = 1
        while (minOf(srcW / sample, srcH / sample) / 2 >= MAX_EDGE_PX) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(
            bytes,
            0,
            bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample }
        ) ?: return null

        val edge = minOf(decoded.width, decoded.height)
        if (edge <= 0) return null
        val square = try {
            Bitmap.createBitmap(
                decoded,
                (decoded.width - edge) / 2,
                (decoded.height - edge) / 2,
                edge,
                edge
            )
        } catch (_: Exception) {
            decoded
        }
        val sized = if (edge > MAX_EDGE_PX) {
            Bitmap.createScaledBitmap(square, MAX_EDGE_PX, MAX_EDGE_PX, true)
        } else {
            square
        }

        var quality = 90
        while (true) {
            val out = ByteArrayOutputStream()
            sized.compress(Bitmap.CompressFormat.JPEG, quality, out)
            val data = out.toByteArray()
            if (data.size <= MAX_FILE_BYTES) return data
            if (quality <= 35) return null
            quality -= 15
        }
    }

    private fun pruneToEntryCap(directory: File) {
        try {
            val files = directory.listFiles()?.sortedByDescending { it.lastModified() } ?: return
            if (files.size <= MAX_ENTRIES) return
            files.drop(MAX_ENTRIES).forEach { it.delete() }
        } catch (_: Exception) {
        }
    }
}
