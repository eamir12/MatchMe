// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
package io.flutter.plugins.sharedpreferences

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.ObjectOutputStream
import org.junit.Assert.assertEquals
import org.junit.Test

class StringListObjectInputStreamTest {
  @Test
  fun readsLegacyKotlinEmptyList() {
    val bytes = ByteArrayOutputStream().use { byteStream ->
      ObjectOutputStream(byteStream).use { it.writeObject(emptyList<String>()) }
      byteStream.toByteArray()
    }

    val decoded =
        StringListObjectInputStream(ByteArrayInputStream(bytes)).use { it.readObject() }

    assertEquals(emptyList<String>(), decoded)
  }

  @Test
  fun encoderWritesAllowlistedJavaListForEmptyInput() {
    val encoder = LegacySharedPreferencesPlugin.ListEncoder()

    assertEquals(emptyList<String>(), encoder.decode(encoder.encode(emptyList())))
  }
}
