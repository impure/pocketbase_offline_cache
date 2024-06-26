
import 'package:logger/logger.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:pocketbase_offline_cache/pocketbase_offline_cache.dart';
import 'package:pocketbase_offline_cache/src/get_records.dart';
import 'package:sqlite3/common.dart';
import 'package:test/test.dart';

import 'pocketbase_offline_cache_test.dart';

class TestLogger implements Logger {
  @override
  Future<void> close() {
    throw UnimplementedError();
  }

  @override
  void d(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("d: $message");
  }

  @override
  void e(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("e: $message");
  }

  @override
  void f(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("f: $message");
  }

  @override
  void i(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("i: $message");
  }

  @override
  Future<void> get init => throw UnimplementedError();

  @override
  bool isClosed() {
    throw UnimplementedError();
  }

  @override
  void log(Level level, dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("$level: $message");
  }

  @override
  void t(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("t: $message");
  }

  @override
  void v(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("v: $message");
  }

  @override
  void w(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("w: $message");
  }

  @override
  void wtf(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
		operations.add("wtf: $message");
  }

}

void main() {

	setUp(() {
		operations.clear();
	});
	tearDown(() {
		operations.clear();
	});

	final PbOfflineCache pb = PbOfflineCache.withDb(PbWrapper(), DatabaseMock());
	final CommonDatabase db = DatabaseMock();
	pb.dbAccessible = true;
	final Logger testLogger = TestLogger();

	group("listRecords", () {
		test("basic getRecords", () async {
			await pb.getRecords("abc");
			expect(operations.toString(), "[getList 1 500 true null]");
		});

		test("limit items getRecords", () async {
			await pb.getRecords("abc", maxItems: 50);
			expect(operations.toString(), "[getList 1 50 true null]");
		});

		test("multi condition 1 getRecords", () async {
			await pb.getRecords("abc", maxItems: 50, where: ("abc = ? && xyz = ?", <int>[1, 2]));
			expect(operations.toString(), "[getList 1 50 true abc = 1 && xyz = 2]");
		});

		test("multi condition 2 getRecords", () async {
			await pb.getRecords("abc", where: ("status = ? && created >= ?", <Object>[true, "2022-08-01"]));
			expect(operations.toString(), "[getList 1 500 true status = true && created >= '2022-08-01']");
		});

		test("single condition getRecords", () async {
			await pb.getRecords("abc", maxItems: 50, where: ("created >= ?", <Object>[DateTime.utc(2024)]));
			expect(operations.toString(), "[getList 1 50 true created >= '2024-01-01 00:00:00.000Z']");
		});

		test("single start after multi condition getRecords descending", () async {
			await pb.getRecords("abc", where: ("status = ? && created >= ?", <Object>[true, "2022-08-01"]), startAfter: <String, dynamic>{"status": true}, sort: ("status", true));
			expect(operations.toString(), "[getList 1 500 true status = true && created >= '2022-08-01' && status < true]");
		});

		test("multi start after no conditions getRecords", () async {
			await pb.getRecords("abc", startAfter: <String, dynamic>{"status": DateTime.utc(2024), "1" : 2}, sort: ("status", false));
			expect(operations.toString(), "[getList 1 500 true status > '2024-01-01 00:00:00.000Z']");
		});
	});

	group("insertRecordsIntoLocalDb", () {

		test("insert empty", () {
			insertRecordsIntoLocalDb(db, "test", <RecordModel>[ RecordModel(
				id: "abc",
				created: DateTime(2024, 1).toString(),
				updated: DateTime(2024, 2).toString(),
			) ], testLogger, overrideDownloadTime: DateTime(2024, 3).toString());
			expect(operations.toString(),
					"[[SELECT name FROM sqlite_master WHERE type='table' AND name=?, [test]], "
					"[CREATE TABLE test (id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT), []], "
					"[INSERT OR REPLACE INTO test(id, created, updated, _downloaded) VALUES(?, ?, ?, ?);, [abc, 2024-01-01 00:00:00.000, 2024-02-01 00:00:00.000, 2024-03-01 00:00:00.000]]]"
			);
		});

		test("insert one item", () {
			insertRecordsIntoLocalDb(db, "test", <RecordModel>[ RecordModel(
				id: "abc",
				data: <String, dynamic> { "1" : 2 },
				created: DateTime(2024, 1).toString(),
				updated: DateTime(2024, 2).toString(),
			) ], testLogger, overrideDownloadTime: DateTime(2024, 3).toString());
			expect(operations.toString(),
				"[[SELECT name FROM sqlite_master WHERE type='table' AND name=?, [test]], "
				"[CREATE TABLE test (id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT,1 REAL DEFAULT 0.0), []], "
				"[INSERT OR REPLACE INTO test(id, created, updated, _downloaded, 1) VALUES(?, ?, ?, ?, ?);, [abc, 2024-01-01 00:00:00.000, 2024-02-01 00:00:00.000, 2024-03-01 00:00:00.000, 2]]]"
			);
		});

		test("insert two items", () {
			insertRecordsIntoLocalDb(db, "test", <RecordModel>[ RecordModel(
				id: "abc",
				data: <String, dynamic> { "1" : true, "2" : DateTime(2022).toString() },
				created: DateTime(2024, 1).toString(),
				updated: DateTime(2024, 2).toString(),
			) ], testLogger, overrideDownloadTime: DateTime(2024, 3).toString());
			expect(operations.toString(),
				"[[SELECT name FROM sqlite_master WHERE type='table' AND name=?, [test]], "
				"[CREATE TABLE test (id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT,_offline_bool_1 INTEGER DEFAULT 0,2 TEXT DEFAULT ''), []], "
				"[INSERT OR REPLACE INTO test(id, created, updated, _downloaded, _offline_bool_1, 2) VALUES(?, ?, ?, ?, ?, ?);, [abc, 2024-01-01 00:00:00.000, 2024-02-01 00:00:00.000, 2024-03-01 00:00:00.000, true, 2022-01-01 00:00:00.000]]]"
			);
		});

		test("single index failled", () {
			insertRecordsIntoLocalDb(db, "test", <RecordModel>[ RecordModel(
				id: "abc",
				data: <String, dynamic> { "1" : 1, "2" : DateTime(2022).toString() },
				created: DateTime(2024, 1).toString(),
				updated: DateTime(2024, 2).toString(),
			) ], testLogger, indexInstructions: <String, List<(String, bool, List<String>)>>{"test" : <(String, bool, List<String>)>[ ("index1", false, <String>["3"]) ]}, overrideDownloadTime: DateTime(2024, 3).toString());
			expect(operations.toString(),
				"[[SELECT name FROM sqlite_master WHERE type='table' AND name=?, [test]], "
				"[CREATE TABLE test (id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT,1 REAL DEFAULT 0.0,2 TEXT DEFAULT ''), []], "
				"e: Unable to create index index1 on test({id, created, updated, _downloaded, 1, 2}), could not find all columns: [3], "
				"[INSERT OR REPLACE INTO test(id, created, updated, _downloaded, 1, 2) VALUES(?, ?, ?, ?, ?, ?);, [abc, 2024-01-01 00:00:00.000, 2024-02-01 00:00:00.000, 2024-03-01 00:00:00.000, 1, 2022-01-01 00:00:00.000]]]"
			);
		});

		test("irrelevant index", () {
			insertRecordsIntoLocalDb(db, "test", <RecordModel>[ RecordModel(
				id: "abc",
				data: <String, dynamic> { "1" : <String>["1", "2"], "2" : DateTime(2022).toString() },
				created: DateTime(2024, 1).toString(),
				updated: DateTime(2024, 2).toString(),
			) ], testLogger, indexInstructions: <String, List<(String, bool, List<String>)>>{"3" : <(String, bool, List<String>)>[ ("index1", false, <String>["4", "5"]) ]}, overrideDownloadTime: DateTime(2024, 3).toString());
			expect(operations.toString(),
				"[[SELECT name FROM sqlite_master WHERE type='table' AND name=?, [test]], "
				"[CREATE TABLE test (id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT,_offline_json_1 TEXT DEFAULT '[]',2 TEXT DEFAULT ''), []], "
				"[INSERT OR REPLACE INTO test(id, created, updated, _downloaded, _offline_json_1, 2) VALUES(?, ?, ?, ?, ?, ?);, [abc, 2024-01-01 00:00:00.000, 2024-02-01 00:00:00.000, 2024-03-01 00:00:00.000, [\"1\",\"2\"], 2022-01-01 00:00:00.000]]]"
			);
		});

		test("double index success", () {
			insertRecordsIntoLocalDb(db, "test", <RecordModel>[ RecordModel(
				id: "abc",
				data: <String, dynamic> { "1" : 1, "2" : DateTime(2022).toString() },
				created: DateTime(2024, 1).toString(),
				updated: DateTime(2024, 2).toString(),
			) ], testLogger, indexInstructions: <String, List<(String, bool, List<String>)>>{"test" : <(String, bool, List<String>)>[
				("index1", false, <String>["1", "2"]),
			]}, overrideDownloadTime: DateTime(2024, 3).toString());
			expect(operations.toString(),
				"[[SELECT name FROM sqlite_master WHERE type='table' AND name=?, [test]], "
				"[CREATE TABLE test (id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT,1 REAL DEFAULT 0.0,2 TEXT DEFAULT ''), []], "
				"[CREATE INDEX index1 ON test(1, 2), []], "
				"[INSERT OR REPLACE INTO test(id, created, updated, _downloaded, 1, 2) VALUES(?, ?, ?, ?, ?, ?);, [abc, 2024-01-01 00:00:00.000, 2024-02-01 00:00:00.000, 2024-03-01 00:00:00.000, 1, 2022-01-01 00:00:00.000]]]"
			);
		});

		test("multiple indexes at the same time (and one unique)", () {
			insertRecordsIntoLocalDb(db, "test", <RecordModel>[ RecordModel(
				id: "abc",
				data: <String, dynamic> { "1" : 1, "2" : DateTime(2022).toString() },
				created: DateTime(2024, 1).toString(),
				updated: DateTime(2024, 2).toString(),
			) ], testLogger, indexInstructions: <String, List<(String, bool, List<String>)>>{"test" : <(String, bool, List<String>)>[
				("index1", true, <String>["1", "2"]),
				("index2", false, <String>["2"]),
			]}, overrideDownloadTime: DateTime(2024, 3).toString());
			expect(operations.toString(),
				"[[SELECT name FROM sqlite_master WHERE type='table' AND name=?, [test]], "
				"[CREATE TABLE test (id TEXT PRIMARY KEY, created TEXT, updated TEXT, _downloaded TEXT,1 REAL DEFAULT 0.0,2 TEXT DEFAULT ''), []], "
				"[CREATE UNIQUE INDEX index1 ON test(1, 2), []], "
				"[CREATE INDEX index2 ON test(2), []], "
				"[INSERT OR REPLACE INTO test(id, created, updated, _downloaded, 1, 2) VALUES(?, ?, ?, ?, ?, ?);, [abc, 2024-01-01 00:00:00.000, 2024-02-01 00:00:00.000, 2024-03-01 00:00:00.000, 1, 2022-01-01 00:00:00.000]]]"
			);
		});
	});
}
