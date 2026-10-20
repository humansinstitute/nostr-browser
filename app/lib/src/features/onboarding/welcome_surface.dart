import 'package:flutter/material.dart';

ThemeData welcomeTheme(BuildContext context) => Theme.of(context).copyWith(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7040AA)),
      filledButtonTheme: FilledButtonThemeData(
          style:
              FilledButton.styleFrom(minimumSize: const Size.fromHeight(50))),
      inputDecorationTheme: const InputDecorationTheme(
          filled: true, fillColor: Colors.white, border: OutlineInputBorder()),
    );

/// Shared background and responsive panel for startup and local identity access.
class WelcomeSurface extends StatelessWidget {
  const WelcomeSurface(
      {required this.child, this.allowBack = false, super.key});
  final Widget child;
  final bool allowBack;
  @override
  Widget build(BuildContext context) {
    final theme = welcomeTheme(context);
    return Theme(
        data: theme,
        child: Scaffold(
            body: Stack(fit: StackFit.expand, children: [
          Image.asset('assets/app-selector/voxel-beach.png',
              fit: BoxFit.cover, excludeFromSemantics: true),
          const ColoredBox(color: Color(0x66322150)),
          SafeArea(
              child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: ConstrainedBox(
                            constraints: BoxConstraints(
                                minHeight: (constraints.maxHeight - 40)
                                    .clamp(0, double.infinity)),
                            child: Center(
                                child: Container(
                              constraints: const BoxConstraints(maxWidth: 460),
                              padding: EdgeInsets.all(
                                  constraints.maxWidth < 400 ? 22 : 32),
                              decoration: BoxDecoration(
                                  color: const Color(0xFFFCFAFF),
                                  borderRadius: BorderRadius.circular(28),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Color(0x40322150),
                                        blurRadius: 40,
                                        offset: Offset(0, 16))
                                  ]),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(children: [
                                      if (allowBack &&
                                          Navigator.of(context).canPop())
                                        const BackButton(),
                                      const Icon(Icons.explore_outlined,
                                          color: Color(0xFFC45D16), size: 24),
                                      const SizedBox(width: 10),
                                      Text('WINGMAN',
                                          style: theme.textTheme.labelLarge
                                              ?.copyWith(
                                                  color:
                                                      const Color(0xFF7040AA),
                                                  letterSpacing: 2.5,
                                                  fontWeight: FontWeight.w700))
                                    ]),
                                    const SizedBox(height: 26),
                                    child,
                                  ]),
                            ))),
                      ))),
        ])));
  }
}

class WelcomeLoadingScreen extends StatelessWidget {
  const WelcomeLoadingScreen({super.key});
  @override
  Widget build(BuildContext context) => WelcomeSurface(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('A little room to explore.',
            style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        const Text('Preparing your local identity…'),
        const SizedBox(height: 24),
        Semantics(
            label: 'Loading Wingman', child: const LinearProgressIndicator()),
      ]));
}
