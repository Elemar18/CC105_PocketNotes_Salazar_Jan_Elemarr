import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

const String kTable = 'expenses';
const String kThemeKey = 'isDark';

// One SharedPreferencesAsync object, reused everywhere.
final SharedPreferencesAsync prefs = SharedPreferencesAsync();

// ---------------------------------------------------------------
// MODEL: one row of the expenses table
// ---------------------------------------------------------------
class Expense {
  final int? id; // null until the database assigns one
  final String item;
  final double amount;

  const Expense({this.id, required this.item, required this.amount});

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'item': item,
        'amount': amount,
      };

  factory Expense.fromMap(Map<String, Object?> m) => Expense(
        id: m['id'] as int,
        item: m['item'] as String,
        amount: (m['amount'] as num).toDouble(),
      );
}

// ---------------------------------------------------------------
// DATABASE: opened ONCE, the same instance is reused everywhere
// ---------------------------------------------------------------
class AppDatabase {
  AppDatabase._(); // private constructor: nobody else can create one
  static final AppDatabase instance = AppDatabase._();

  // Caching the Future (not just the Database) means that even if two
  // callers ask at the same moment, openDatabase only runs one time.
  Future<Database>? _dbFuture;
  Future<Database> get db => _dbFuture ??= _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'pocket_notes_expenses.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE $kTable ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'item TEXT NOT NULL, '
          'amount REAL NOT NULL)',
        );
      },
    );
  }

  Future<List<Expense>> all() async {
    final d = await db;
    final rows = await d.query(kTable, orderBy: 'id ASC');
    return rows.map(Expense.fromMap).toList();
  }

  Future<int> insert(Expense e) async {
    final d = await db;
    return d.insert(kTable, e.toMap());
  }

  // where + whereArgs: the ? is filled in safely, no string-gluing.
  Future<int> update(Expense e) async {
    final d = await db;
    return d.update(
      kTable,
      {'item': e.item, 'amount': e.amount},
      where: 'id = ?',
      whereArgs: [e.id],
    );
  }

  Future<int> delete(int id) async {
    final d = await db;
    return d.delete(
      kTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

// ---------------------------------------------------------------
// STARTUP: read the saved theme BEFORE runApp so the first frame
// is already the right theme (no wrong-theme flash).
// ---------------------------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final savedDark = await prefs.getBool(kThemeKey) ?? false;
  runApp(PocketNotesApp(initialDark: savedDark));
}

class PocketNotesApp extends StatefulWidget {
  final bool initialDark;
  const PocketNotesApp({super.key, required this.initialDark});

  @override
  State<PocketNotesApp> createState() => _PocketNotesAppState();
}

class _PocketNotesAppState extends State<PocketNotesApp> {
  late bool _isDark = widget.initialDark;

  Future<void> _setDark(bool value) async {
    setState(() => _isDark = value);
    await prefs.setBool(kThemeKey, value); // saved to disk
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pocket Notes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.light,
          useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
          useMaterial3: true),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      home: HomePage(isDark: _isDark, onThemeChanged: _setDark),
    );
  }
}

// ---------------------------------------------------------------
// UI: one screen, a list, an add/edit dialog, a theme switch
// ---------------------------------------------------------------
class HomePage extends StatefulWidget {
  final bool isDark;
  final ValueChanged<bool> onThemeChanged;
  const HomePage(
      {super.key, required this.isDark, required this.onThemeChanged});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Expense> _entries = [];
  bool _loading = true;

  // EXPERIMENT 2: lives only in memory (a plain State variable).
  // It is NOT saved anywhere.
  bool _bigOnly = false;

  @override
  void initState() {
    super.initState();
    _refresh(); // load records from sqflite when the app launches
  }

  Future<void> _refresh() async {
    final rows = await AppDatabase.instance.all();
    // For Capture 7: prints the same rows the list shows.
    debugPrint('DB rows: ${await (await AppDatabase.instance.db).query(kTable)}');
    if (!mounted) return;
    setState(() {
      _entries = rows;
      _loading = false;
    });
  }

  Future<void> _openDialog({Expense? existing}) async {
    final itemCtrl = TextEditingController(text: existing?.item ?? '');
    final amountCtrl =
        TextEditingController(text: existing?.amount.toString() ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add expense' : 'Edit expense'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: itemCtrl,
              decoration: const InputDecoration(labelText: 'Item'),
            ),
            TextField(
              controller: amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (saved != true) return;
    final item = itemCtrl.text.trim();
    final amount = double.tryParse(amountCtrl.text.trim());
    if (item.isEmpty || amount == null) return;

    if (existing == null) {
      await AppDatabase.instance.insert(Expense(item: item, amount: amount));
    } else {
      await AppDatabase.instance
          .update(Expense(id: existing.id, item: item, amount: amount));
    }
    await _refresh();
  }

  Future<void> _delete(Expense e) async {
    await AppDatabase.instance.delete(e.id!);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final shown =
        _bigOnly ? _entries.where((e) => e.amount >= 100).toList() : _entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pocket Notes: Expenses'),
        actions: [
          const Icon(Icons.light_mode),
          Switch(value: widget.isDark, onChanged: widget.onThemeChanged),
          const Icon(Icons.dark_mode),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openDialog(),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                label: const Text('100+ only'),
                selected: _bigOnly,
                onSelected: (v) => setState(() => _bigOnly = v),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : shown.isEmpty
                    ? const Center(child: Text('No expenses. Tap + to add one.'))
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final e = shown[i];
                          return ListTile(
                            title: Text(e.item),
                            subtitle: Text(
                                'id ${e.id}  |  amount ${e.amount.toStringAsFixed(2)}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit),
                                  onPressed: () => _openDialog(existing: e),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () => _delete(e),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}