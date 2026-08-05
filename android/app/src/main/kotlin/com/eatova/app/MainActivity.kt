package com.eatova.app

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (statt FlutterActivity), weil das health-Plugin
// eine ComponentActivity braucht - mit FlutterActivity schlug seine
// Registrierung mit ClassCastException fehl (Health-Sync auf Android tot).
class MainActivity : FlutterFragmentActivity()
