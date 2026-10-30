import 'package:sembast_web/sembast_web.dart';

Future<Database> openLedgerDatabase() =>
    databaseFactoryWeb.openDatabase('balance');
