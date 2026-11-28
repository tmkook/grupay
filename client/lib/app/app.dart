import 'package:flutter/material.dart';

import '../core/screen_guard.dart';
import '../features/auth/login_page.dart';

class GruPayApp extends StatelessWidget {
  const GruPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF46658A);
    const navy = Color(0xFF293442);
    const border = Color(0xFFDFE3E4);
    const surface = Color(0xFFFFFFFF);
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );
    final colors = ColorScheme.fromSeed(seedColor: blue).copyWith(
      primary: blue,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFE5EBF1),
      onPrimaryContainer: const Color(0xFF354E69),
      surface: surface,
      surfaceContainerLow: const Color(0xFFF8F8F6),
      surfaceContainer: const Color(0xFFF2F3F2),
      surfaceContainerHigh: const Color(0xFFEEF0EF),
      surfaceContainerHighest: const Color(0xFFE8EBEB),
      onSurface: navy,
      onSurfaceVariant: const Color(0xFF58646E),
      outlineVariant: border,
    );
    return MaterialApp(
      title: 'GruPay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colors,
        scaffoldBackgroundColor: const Color(0xFFFAFAF8),
        appBarTheme: const AppBarTheme(
          scrolledUnderElevation: 0,
          backgroundColor: Color(0xFFFAFAF8),
          foregroundColor: navy,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: const CardThemeData(
          color: surface,
          elevation: 3,
          shadowColor: Color(0x3654616A),
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: border),
          ),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: surface,
          surfaceTintColor: Colors.transparent,
          shadowColor: Color(0x4654616A),
          shape: shape,
        ),
        dividerTheme: const DividerThemeData(color: border),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          indicatorColor: colors.primaryContainer,
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? blue
                  : colors.onSurfaceVariant,
            ),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: blue,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            elevation: 3,
            shadowColor: const Color(0x40465869),
            shape: shape,
            minimumSize: const Size(0, 46),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: border),
          ),
          fillColor: Color(0xFFF1F3F3),
          filled: true,
        ),
      ),
      builder: (_, child) => ScreenGuard(child: child!),
      home: const LoginPage(),
    );
  }
}
