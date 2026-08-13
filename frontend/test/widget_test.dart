import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders application name', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('FotoSearch')));
    expect(find.text('FotoSearch'), findsOneWidget);
  });
}
