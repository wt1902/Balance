// Another desktop process for test/desktop_lock_test.dart: takes the same
// exclusive file lock, reports it, and holds it until stdin gets a line.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final handle = await File(args.single).open(mode: FileMode.append);
  await handle.lock(FileLock.blockingExclusive);
  stdout.writeln('locked');
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  await handle.unlock();
  await handle.close();
}
