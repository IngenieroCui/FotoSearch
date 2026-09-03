import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const galleryPermissionOption = PermissionRequestOption(
  androidPermission: AndroidPermission(
    type: RequestType.image,
    mediaLocation: false,
  ),
);

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onComplete});
  final VoidCallback onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final controller = PageController();
  int page = 0;
  PermissionState? permission;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && page == 2) {
      unawaited(_refreshPermission());
    }
  }

  Future<void> _refreshPermission() async {
    final value = await PhotoManager.getPermissionState(
      requestOption: galleryPermissionOption,
    );
    if (mounted) setState(() => permission = value);
  }

  Future<void> _requestPermission() async {
    final value = await PhotoManager.requestPermissionExtend(
      requestOption: galleryPermissionOption,
    );
    if (mounted) setState(() => permission = value);
  }

  void _next() => controller.nextPage(
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOut,
  );

  Future<void> _finish() async {
    await (await SharedPreferences.getInstance()).setBool(
      'fotosearch_onboarding_v1_complete',
      true,
    );
    widget.onComplete();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: PageView(
              controller: controller,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (value) => setState(() => page = value),
              children: [
                _Page(
                  icon: Icons.auto_awesome,
                  title: 'Encuentra cualquier recuerdo',
                  text: 'Busca tus fotos escribiendo lo que recuerdas: una persona, un objeto, un color, un lugar o una combinación.',
                  extra: const Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text('camiseta roja')),
                      Chip(label: Text('perro negro')),
                      Chip(label: Text('foto en la playa')),
                    ],
                  ),
                  button: FilledButton(
                    onPressed: _next,
                    child: const Text('Siguiente'),
                  ),
                ),
                _Page(
                  icon: Icons.lock_outline,
                  title: 'Tus fotos se quedan contigo',
                  text: 'FotoSearch analiza e indexa tus imágenes directamente en el teléfono. Tus fotos y sus embeddings visuales no se suben al servidor.',
                  button: FilledButton(
                    onPressed: _next,
                    child: const Text('Siguiente'),
                  ),
                ),
                _Page(
                  icon: Icons.photo_library_outlined,
                  title: 'Necesitamos tu galería',
                  text: 'Para encontrar cualquier foto, FotoSearch necesita acceso a todas las imágenes de tu galería.',
                  extra: _PermissionMessage(permission: permission),
                  button: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (permission?.hasAccess == true &&
                          permission?.isLimited == false)
                        FilledButton.icon(
                          onPressed: _next,
                          icon: const Icon(Icons.check),
                          label: const Text('Siguiente'),
                        )
                      else if (permission?.isLimited == true)
                        FilledButton(
                          onPressed: PhotoManager.openSetting,
                          child: const Text('Abrir permisos'),
                        )
                      else ...[
                        FilledButton(
                          onPressed: _requestPermission,
                          child: const Text(
                            'Permitir acceso a todas mis fotos',
                          ),
                        ),
                        if (permission != null)
                          TextButton(
                            onPressed: PhotoManager.openSetting,
                            child: const Text('Abrir ajustes'),
                          ),
                      ],
                    ],
                  ),
                ),
                _Page(
                  icon: Icons.manage_search,
                  title: 'Primero crea tu índice',
                  text: 'La primera vez FotoSearch analizará tu galería. Puede tardar varios minutos dependiendo de cuántas fotos tengas y de la velocidad de tu teléfono.',
                  extra: const Column(
                    children: [
                      _Step(number: 1, text: 'Escanea tu galería'),
                      _Step(
                        number: 2,
                        text: 'Espera mientras se crea el índice',
                      ),
                      _Step(number: 3, text: 'Busca cualquier recuerdo'),
                      SizedBox(height: 12),
                      Text(
                        'Después solo se procesarán las fotos nuevas o modificadas.',
                      ),
                    ],
                  ),
                  button: FilledButton(
                    onPressed: _finish,
                    child: const Text('Empezar'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                4,
                (index) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: page == index ? 24 : 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: page == index
                        ? Theme.of(context).colorScheme.primary
                        : Colors.black12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    required this.text,
    required this.button,
    this.extra,
  });
  final IconData icon;
  final String title;
  final String text;
  final Widget? extra;
  final Widget button;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 48, 28, 20),
    child: Column(
      children: [
        Icon(icon, size: 72, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 30),
        Text(
          title,
          style: Theme.of(context).textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          text,
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        if (extra != null) ...[const SizedBox(height: 24), extra!],
        const Spacer(),
        SizedBox(width: double.infinity, child: button),
      ],
    ),
  );
}

class _PermissionMessage extends StatelessWidget {
  const _PermissionMessage({required this.permission});
  final PermissionState? permission;

  @override
  Widget build(BuildContext context) {
    if (permission?.hasAccess == true && permission?.isLimited == false) {
      return const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle, color: Colors.green),
          SizedBox(width: 8),
          Text('Acceso completo concedido'),
        ],
      );
    }
    if (permission?.isLimited == true) {
      return const Text(
        'FotoSearch solo puede ver algunas fotos. Para buscar en toda tu galería debes permitir acceso completo.',
        textAlign: TextAlign.center,
      );
    }
    if (permission != null) {
      return const Text(
        'El acceso fue denegado. Puedes intentarlo otra vez o abrir los ajustes del dispositivo.',
        textAlign: TextAlign.center,
      );
    }
    return const SizedBox.shrink();
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});
  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: CircleAvatar(radius: 14, child: Text('$number')),
    title: Text(text),
  );
}
