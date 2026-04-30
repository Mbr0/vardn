import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_p2p/app.dart';

void main() {
  testWidgets('App boots to home screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: TodoP2PApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('All todos'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  });
}
