
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path/path.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sqlite3/sqlite3.dart';

import 'count_records.dart';
import 'get_records.dart';

// PocketBase does not support getting more than 500 items at once
const int defaultMaxItems = 500;

enum QuerySource {
	server,
	cache,
	any,
}

bool isTest() => Platform.environment.containsKey('FLUTTER_TEST');

bool dbAccessible = true;

class PbOfflineCache {

	factory PbOfflineCache(PocketBase pb, String directoryToSave, {
		Logger? overrideLogger,
		Map<String, List<(String name, bool unique, List<String> columns)>>? indexInstructions,
	}) {
		return PbOfflineCache._(pb, sqlite3.open(join(directoryToSave, "offline_cache")), overrideLogger ?? Logger(), indexInstructions ?? const <String, List<(String name, bool unique, List<String>)>>{});
	}

	PbOfflineCache._(this.pb, this.db, this.logger, [this.indexInstructions = const <String, List<(String name, bool unique, List<String>)>>{}]) {
		db.execute("""
	CREATE TABLE IF NOT EXISTS _operation_queue (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		operation_type TEXT,
		created INTEGER,
		collection_name TEXT,
		id_to_modify TEXT
	)""");
		db.execute("""
	CREATE TABLE IF NOT EXISTS _operation_queue_params (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		operation_id INTEGER,
		param_key TEXT,
		param_value TEXT,
		type TEXT,
		FOREIGN KEY(operation_id) REFERENCES operations(id)
	)""");

		if (!isTest()) {
			unawaited(_continuouslyCheckDbAccessible());
		}
	}

	factory PbOfflineCache.withDb(PocketBase pb, Database db, {Logger? overrideLogger}) {
		return PbOfflineCache._(pb, db, overrideLogger ?? Logger());
	}

	Future<void> dropAllTables(String directoryToSave) async {
		try {
			final ResultSet tables = db.select("SELECT name FROM sqlite_master WHERE type = 'table'");

			for (final Row table in tables) {
				final String tableName = table['name'] as String;

				// Autogenerated by SQLite, ignore
				if (tableName == "sqlite_sequence") {
					continue;
				}

				// Don't drop these tables because they're probably empty and that causes errors
				if (tableName == "_operation_queue" || tableName == "_operation_queue_params") {
					continue;
				}

				db.execute('DROP TABLE IF EXISTS $tableName');
				logger.i('Dropped table: $tableName');
			}

			logger.i('All tables dropped successfully');
		} catch (e) {
			logger.w('Error during dropAllTables: $e');
		} finally {
			try {
				db.execute('VACUUM;');
				logger.i('Database vacuumed successfully');
			} catch (e) {
				logger.w('Error during vacuum: $e');
			}
		}
	}

	final PocketBase pb;
	Database db;
	final Logger logger;
	final Map<String, List<(String name, bool unique, List<String> columns)>> indexInstructions;

	String? get id => pb.authStore.model?.id;
	bool get tokenValid => pb.authStore.isValid;

	Future<void> _continuouslyCheckDbAccessible() async {
		while (true) {
			try {
				final http.Response response = await http.get(pb.buildUrl("/api/health"));
				if (response.statusCode != 200) {
					dbAccessible = false;
				} else {
					dbAccessible = true;
					await dequeueCachedOperations();
				}
			} on SocketException catch (e) {
				if (!e.message.contains("refused")) {
					rethrow;
				}
				dbAccessible = false;
			}
			await Future<void>.delayed(const Duration(seconds: 10));
		}
	}

	Future<void> dequeueCachedOperations() async {
		final ResultSet data = db.select("SELECT * FROM _operation_queue ORDER BY created ASC");

		for (final Row row in data) {
			final String operationId = row.values[0].toString();
			final String operationType = row.values[1].toString();
			final String collectionName = row.values[3].toString();
			final String pbId = row.values[4].toString();

			final ResultSet data = db.select("SELECT * FROM _operation_queue_params WHERE operation_id = ?", <String>[ operationId ]);
			final Map<String, dynamic> params = <String, dynamic>{};
			for (final Row row in data) {

				dynamic value;

				if (row.values[4] == "bool") {
					value = row.values[3] == "1" ? true : false;
				} else if (row.values[4] == "int") {
					value = int.tryParse(row.values[3].toString());
				} else if (row.values[4] == "double") {
					value = double.tryParse(row.values[3].toString());
				} else if (row.values[4] == "String") {
					value = row.values[3];
				} else {
					logger.e("Unknown type when loading: ${row.values[4]}");
				}

				params[row.values[2].toString()] = value;
			}

			void cleanUp() {
				db.execute("DELETE FROM _operation_queue WHERE id = ?", <String>[ operationId ]);
				db.execute("DELETE FROM _operation_queue_params WHERE id = ?", <String>[ operationId ]);
			}

			// If we failed to update data (probably due to a key constraint) then we need to delete the local copy of the record as well or we'll be out of sync
			void deleteLocalRecord() {
				db.execute("DELETE FROM $collectionName WHERE id = ?", <String>[ pbId ]);
				cleanUp();
			}

			switch (operationType) {
				case "UPDATE":
					try {
						await pb.collection(collectionName).update(pbId, body: params);
						cleanUp();
					} on ClientException catch (e) {
						if (!e.toString().contains("refused the network connection")) {
							logger.e(e, stackTrace: StackTrace.current);
							deleteLocalRecord();
						}
					}
					break;
				case "DELETE":
					try {
						await pb.collection(collectionName).delete(pbId);
						cleanUp();
					} on ClientException catch (e) {
						if (!e.toString().contains("refused the network connection")) {
							logger.e(e, stackTrace: StackTrace.current);
							cleanUp();
						}
					}
					break;
				case "INSERT":
					try {
						params["id"] = pbId;
						await pb.collection(collectionName).create(body: params);
						cleanUp();
					} on ClientException catch (e) {
						if (!e.toString().contains("refused the network connection")) {
							logger.e(e, stackTrace: StackTrace.current);
							deleteLocalRecord();
						}
					}
					break;
				default:
					logger.e("Unknown operation type: $operationType, row: $row");
			}
		}
	}

	Future<void> refreshAuth() async {
		try {
			await pb.collection('users').authRefresh();
		} on ClientException catch (e) {
			if (!e.toString().contains("refused the network connection")) {
				rethrow;
			}
		}
	}

	void queueOperation(
		String operationType,
		String collectionName,
		{Map<String, dynamic>? values, String idToModify = ""}
	) {

		// This is not guaranteed to be unique but if two commands are executed at the same time the order doesn't really matter
		final int created = DateTime.now().millisecondsSinceEpoch;

		final ResultSet record = db.select("INSERT INTO _operation_queue (operation_type, created, collection_name, id_to_modify) VALUES ('$operationType', $created, '$collectionName', ?) RETURNING id", <Object>[ idToModify ]);
		final int id = record.first.values.first! as int;

		if (values != null) {
			for (final MapEntry<String, dynamic> entry in values.entries) {

				String? type;

				if (entry.value is bool) {
					type = "bool";
				} else if (entry.value is int) {
					type = "int";
				} else if (entry.value is double) {
					type = "double";
				} else if (entry.value is String) {
					type = "String";
				} else {
					logger.e("Unknown type: ${entry.value.runtimeType}");
				}

				db.select("INSERT INTO _operation_queue_params (operation_id, param_key, param_value, type) VALUES (?, ?, ?, ?)", <Object?>[id, entry.key, entry.value, type]);
			}
		}
	}

	QueryBuilder collection(String collectionName) {
		return QueryBuilder._(this, collectionName, "", <dynamic>[] );
	}
}

bool tableExists(Database db, String tableName) {
	return db.select(
		"SELECT name FROM sqlite_master WHERE type='table' AND name=?",
		<String> [ tableName ],
	).isNotEmpty;
}

ResultSet selectBuilder(Database db, String tableName, {
	String? columns,
	(String, List<Object?>)? filter,
	int? maxItems,
	(String, bool descending)? sort,
	Map<String, dynamic>? startAfter,
}) {

	final StringBuffer query = StringBuffer("SELECT ${columns ?? "*"} FROM $tableName");

	String generateSortCondition(Map<String, dynamic>? startAfter, bool and) {
		if (startAfter == null || startAfter.isEmpty) {
			return "";
		}

		final List<String> removeKeys = <String>[];

		for (final MapEntry<String, dynamic> data in startAfter.entries) {
			if (data.value is bool || data.value is List<dynamic> || data.value is Map<dynamic, dynamic> || data.value is DateTime || data.value is Uri) {
				removeKeys.add(data.key);
			}
		}

		removeKeys.forEach(startAfter.remove);

		final List<String> keys = startAfter.keys.toList();
		final List<dynamic> values = startAfter.values.toList();

		final String keysPart = keys.join(', ');
		final String valuesPart = values.map((dynamic val) {
			return "?";
		}).join(', ');

		return '${and ? " AND " : ""}($keysPart) > ($valuesPart)';
	}

	String preprocessQuery(String query, List<dynamic> params) {
		final List<String> operators = <String>['=', '!=', '>=', '>', '<=', '<'];
		final String regexPattern = operators.map((String op) => RegExp.escape(op)).join('|');
		final RegExp regex = RegExp(r'(.*?)(' + regexPattern + r')(.*)');

		final List<String> parts = query.split('&&');
		final List<String> updatedParts = <String>[];
		int paramIndex = 0;

		for (final String part in parts) {
			if (paramIndex < params.length && params[paramIndex] is bool) {
				final RegExpMatch? match = regex.firstMatch(part);
				if (match != null) {
					final String columnName = match.group(1) ?? '';
					final String operator = match.group(2) ?? '';
					final String rest = match.group(3) ?? '';

					final String updatedPart = "_offline_bool_${columnName.trimLeft()}$operator$rest";
					updatedParts.add(updatedPart);
				} else {
					updatedParts.add(part);
				}
			} else {
				updatedParts.add(part);
			}
			paramIndex++;
		}

		return updatedParts.join('AND ');
	}

	if (filter != null) {
		query.write(" WHERE ${preprocessQuery(filter.$1, filter.$2)}${generateSortCondition(startAfter, true)}");
		if (startAfter != null) {
			filter.$2.addAll(startAfter.values);
		}
	} else if (startAfter != null) {
		query.write(" WHERE ${generateSortCondition(startAfter, false)}");
		filter = ("", startAfter.values.toList());
	}

	if (sort != null) {
		query.write(" SORT BY ${sort.$1} ${sort.$2 ? "DESC" : "ASC"}");
	}

	if (maxItems != null) {
		query.write(" LIMIT $maxItems");
	}

	query.write(";");

	if (filter != null) {

		for (int i = 0; i < filter.$2.length; i++) {
			if (filter.$2[i] is DateTime) {
				filter.$2[i] = filter.$2[i].toString();
			} else if (filter.$2[i] == null) {
				filter.$2[i] = "";
			}
		}

		return db.select(query.toString(), filter.$2);
	} else {
		return db.select(query.toString());
	}
}

class QueryBuilder {

	const QueryBuilder._(this.pb, this.collectionName, this.currentFilter, this.args, [this.orderRule]);

	final PbOfflineCache pb;
	final String collectionName;
	final String currentFilter;
	final List<dynamic> args;
	final (String, bool descending)? orderRule;

	@override
	String toString() => "$collectionName $currentFilter $args $orderRule";

	QueryBuilder where(String column, {
		dynamic isEqualTo,
		dynamic isNotEqualTo,
		dynamic isGreaterThan,
		dynamic isLessThan,
		dynamic isGreaterThanOrEqualTo,
		dynamic isLessThanOrEqualTo,
		bool? isNull,
	}) {
		assert((isEqualTo != null ? 1 : 0)
				+ (isNotEqualTo != null ? 1 : 0)
				+ (isGreaterThan != null ? 1 : 0)
				+ (isLessThan != null ? 1 : 0)
				+ (isGreaterThanOrEqualTo != null ? 1 : 0)
				+ (isLessThanOrEqualTo != null ? 1 : 0)
				+ (isNull != null ? 1 : 0) == 1);

		if (isNull == true) {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column = ?", List<dynamic>.from(args)..add(null), orderRule);
		} else if (isNull == false) {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column != ?", List<dynamic>.from(args)..add(null), orderRule);
		} else if (isEqualTo != null) {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column = ?", List<dynamic>.from(args)..add(isEqualTo), orderRule);
		} else if (isNotEqualTo != null) {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column != ?", List<dynamic>.from(args)..add(isNotEqualTo), orderRule);
		} else if (isGreaterThan != null) {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column > ?", List<dynamic>.from(args)..add(isGreaterThan), orderRule);
		} else if (isLessThan != null) {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column < ?", List<dynamic>.from(args)..add(isLessThan), orderRule);
		} else if (isLessThanOrEqualTo != null) {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column <= ?", List<dynamic>.from(args)..add(isLessThanOrEqualTo), orderRule);
		} else {
			return QueryBuilder._(pb, collectionName,
					"${currentFilter != "" ? "$currentFilter && " : ""}$column >= ?", List<dynamic>.from(args)..add(isGreaterThanOrEqualTo), orderRule);
		}
	}

	QueryBuilder orderBy(String columnName, { bool descending = true }) {
		assert(orderRule == null, "Multiple order by not supported");
		return QueryBuilder._(pb, collectionName, currentFilter, args, (columnName, descending));
	}

	Future<List<Map<String, dynamic>>> get({ int maxItems = defaultMaxItems, QuerySource source = QuerySource.any, Map<String, dynamic>? startAfter }) {
		return pb.getRecords(collectionName, where: (currentFilter, args), maxItems: maxItems, source: source, sort: orderRule, startAfter: startAfter);
	}

	Future<int?> getCount({ QuerySource source = QuerySource.any }) {
		return pb.getRecordCount(collectionName, where: (currentFilter, args), source: source);
	}
}
