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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 2,
        ),
        cardTheme: CardThemeData(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
