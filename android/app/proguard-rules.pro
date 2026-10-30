# kotlinx.serialization: generierte Serializer der @Serializable-Klassen behalten.
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class de.letzgo.porridge.**$$serializer { *; }
-keepclassmembers class de.letzgo.porridge.** { *** Companion; }
-keepclasseswithmembers class de.letzgo.porridge.** { kotlinx.serialization.KSerializer serializer(...); }

-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# sherpa-onnx ruft seine Kotlin-Konfigurationsklassen per JNI über Feldnamen auf.
-keep class com.k2fsa.sherpa.onnx.** { *; }

# security-crypto (Tink) verweist auf Errorprone-Annotationen, die zur Laufzeit nicht gebraucht werden.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
