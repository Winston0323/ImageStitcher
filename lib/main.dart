import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ImageStitchingApp());
}

class ImageStitchingApp extends StatelessWidget {
  const ImageStitchingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '图片拼接工具',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        colorScheme: ColorScheme.dark(
          surface: const Color(0xFF2A2A2A),
          primary: Colors.blue[300]!,
          onPrimary: Colors.black,
          secondary: Colors.blue[200]!,
          onSurface: Colors.white,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 2,
          backgroundColor: Color(0xFF252525),
        ),
        cardTheme: CardThemeData(
          elevation: 4,
          color: const Color(0xFF2A2A2A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
