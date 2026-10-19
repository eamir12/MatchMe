// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.sharedpreferences

import java.io.IOException
import java.io.InputStream
import java.io.ObjectInputStream
import java.io.ObjectStreamClass

/**
 * An ObjectInputStream that only allows string lists, to prevent injected prefs from instantiating
 * arbitrary objects.
 */
class StringListObjectInputStream(input: InputStream) : ObjectInputStream(input) {
  @Throws(ClassNotFoundException::class, IOException::class)
  override fun resolveClass(desc: ObjectStreamClass?): Class<*>? {
    val allowList =
        setOf(
            "java.util.Arrays\$ArrayList",
            "java.util.ArrayList",
            "java.lang.String",
            "[Ljava.lang.String;")
    val name = desc?.name
    if (name == null || !allowList.contains(name)) {
      // Older plugin releases could serialize Kotlin's empty-list singleton
      // while migrating a legacy StringSet. R8 may rename that class, so do
      // not rely on its serialized name. Its stream descriptor is fieldless;
      // match its serial UID to the runtime's trusted EmptyList descriptor and
      // resolve it to that known-safe class. No arbitrary serialized class is
      // instantiated by this compatibility path.
      val emptyListClass = emptyList<Any>().javaClass
      val emptyListDescriptor = ObjectStreamClass.lookup(emptyListClass)
      if (desc != null &&
          desc.fields.isEmpty() &&
          emptyListDescriptor != null &&
          desc.serialVersionUID == emptyListDescriptor.serialVersionUID) {
        return emptyListClass
      }
      throw ClassNotFoundException(name ?: "Unknown serialized class")
    }
    return super.resolveClass(desc)
  }
}
