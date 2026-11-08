package net.jwalter.lotsofevents;

import android.content.Context;
import android.security.keystore.*;
import android.util.Base64;
import java.security.KeyStore;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

final class Vault {
  private final Context context;

  Vault(Context c) {
    context = c;
  }

  private javax.crypto.SecretKey key() throws Exception {
    KeyStore store = KeyStore.getInstance("AndroidKeyStore");
    store.load(null);
    if (!store.containsAlias("icloud")) {
      KeyGenerator g = KeyGenerator.getInstance("AES", "AndroidKeyStore");
      g.init(
          new KeyGenParameterSpec.Builder(
                  "icloud", KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
              .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
              .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
              .build());
      g.generateKey();
    }
    return (javax.crypto.SecretKey) store.getKey("icloud", null);
  }

  void save(String email, String password) throws Exception {
    Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
    c.init(Cipher.ENCRYPT_MODE, key());
    String encrypted =
        Base64.encodeToString(
            c.doFinal((email + "\n" + password).getBytes(java.nio.charset.StandardCharsets.UTF_8)),
            Base64.NO_WRAP);
    if (!context
        .getSharedPreferences("vault", 0)
        .edit()
        .putString("iv", Base64.encodeToString(c.getIV(), Base64.NO_WRAP))
        .putString("data", encrypted)
        .commit()) throw new Exception("Could not save account securely.");
  }

  String[] read() throws Exception {
    var p = context.getSharedPreferences("vault", 0);
    String data = p.getString("data", null);
    if (data == null) return null;
    Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
    c.init(
        Cipher.DECRYPT_MODE,
        key(),
        new GCMParameterSpec(128, Base64.decode(p.getString("iv", ""), Base64.NO_WRAP)));
    return new String(
            c.doFinal(Base64.decode(data, Base64.NO_WRAP)), java.nio.charset.StandardCharsets.UTF_8)
        .split("\n", 2);
  }

  void clear() {
    context.getSharedPreferences("vault", 0).edit().clear().commit();
  }
}
