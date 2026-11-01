package com.baseflow.geolocator

import android.content.SharedPreferences
import org.json.JSONObject

/**
 * The chat card copy, in the member's language, for the cards Android builds
 * itself.
 *
 * Two producers need it: the foreground service, which replaces the card the
 * FCM SDK drew, and the WorkManager poll, which is the only card a member sees
 * when no push landed at all (force-stop, offline at delivery, token dead).
 * They used to hold their own wording, so a message that arrived by push and a
 * message that arrived by poll could say different things about the same chat.
 * Neither owns the copy now.
 *
 * Dart writes the forms it resolved for the display language into
 * flutter.notifications_chat_copy as one JSON object
 * (`{"messagesTitle":{"one":…,"two":…,"other":…},…}`) and English is used until
 * the first sync lands. push-message already ships finished copy in every
 * payload, so this serves only the paths without one.
 *
 * Dart picks the plural form per count with the language's own CLDR rules, so a
 * locale without a dual row sends its plural form in its place and no language
 * code has to cross the channel.
 */
object ChatNotificationCopy {

    /** "3 messages from John S." - the title names the backlog instead of a
     *  canned "New message", which says nothing the tray icon doesn't. */
    fun messagesTitle(prefs: SharedPreferences?, count: Int, senderName: String): String {
        val n = unreadCount(count)
        return form(prefs, "messagesTitle", n)
            .replace("{count}", n.toString())
            .replace("{name}", senderName)
    }

    /** Previews off: the body states how much is waiting and quotes no text. */
    fun openToReadBody(prefs: SharedPreferences?, count: Int): String {
        val n = unreadCount(count)
        return form(prefs, "openToReadBody", n).replace("{count}", n.toString())
    }

    /** A card never states zero: an absent or stale RPC column still means
     *  "something is waiting". */
    fun unreadCount(count: Int): Int = if (count < 1) 1 else count

    private fun form(prefs: SharedPreferences?, key: String, count: Int): String {
        val forms = try {
            val raw = prefs?.getString("flutter.notifications_chat_copy", null)
            if (raw.isNullOrBlank()) null else JSONObject(raw).optJSONObject(key)
        } catch (_: Exception) {
            null
        } ?: return englishForm(key, count)

        val other = forms.optString("other").takeIf { it.isNotBlank() }
            ?: return englishForm(key, count)
        val slot = if (count == 1) "one" else if (count == 2) "two" else "other"
        return if (slot == "other") other
        else forms.optString(slot).takeIf { it.isNotBlank() } ?: other
    }

    /** English plural forms, used when the language sync has not run yet. */
    private fun englishForm(key: String, count: Int): String = when (key) {
        "messagesTitle" ->
            if (count == 1) "{count} message from {name}" else "{count} messages from {name}"
        else -> "$count unread - open to read"
    }

    // Mirrors public.mask_full_name(TEXT): "First L." for multi-word names
    // (first name + last initial, e.g. "John S."). A name that cannot produce
    // that shape - empty or a single word - falls back to "Someone"; a bare
    // first name is never shown. Idempotent: the RPC and server pushes
    // already return "John S." - re-masking passes it through - so every tray
    // title matches what the app's other screens show.
    fun maskFullName(raw: String?): String {
        val parts = raw?.trim()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() }.orEmpty()
        if (parts.size < 2) return "Someone"
        val first = capWord(parts[0])
        val last = parts[parts.size - 1]
        val initial = last.firstOrNull()?.uppercaseChar() ?: return "Someone"
        return "$first $initial."
    }

    // "jOHN" -> "John", "jean-pierre" -> "Jean-Pierre", "o'brien" -> "O'Brien".
    private fun capWord(word: String): String =
        word.split(Regex("([-'])")).joinToString("") { seg ->
            if (seg == "-" || seg == "'" || seg.isEmpty()) seg
            else seg[0].uppercaseChar() + seg.substring(1).lowercase()
        }
}
