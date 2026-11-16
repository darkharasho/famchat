import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FamChat')),
      body: Center(
        child: FilledButton(
          onPressed: () => context.go('/spikes'),
          child: const Text('Platform spikes'),
        ),
      ),
    );
  }
}
