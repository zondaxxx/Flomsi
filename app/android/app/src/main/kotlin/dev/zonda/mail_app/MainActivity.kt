package dev.zonda.mail_app

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // The Rust core keeps passwords in the Keystore, which it reaches through the
        // app's context: hand it over before Dart starts and anything signs in.
        System.loadLibrary("mail_bridge")
        initNdkContext(applicationContext)
        super.onCreate(savedInstanceState)
    }

    private external fun initNdkContext(context: Context)
}
