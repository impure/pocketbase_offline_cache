
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path/path.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sqlite3/common.dart';

import 'count_records.dart';
import 'get_records.dart';
import 'make_db.dart' if (dart.library.io) 'make_db_io.dart' if (dart.library.html) 'make_db_web.dart';

/// PocketBase does not support getting more than 500 items at once so limit it to that amount. Maybe in the future we can increase it
const int defaultMaxItems = 500;

/// Get our results only from the server, only from the cache, or try server first and then the cache
/// Failures from the cache only or any will return an empty response, failures from server only will throw an exception
enum QuerySource {
	server,
	cache,
	any,
}

bool isTest() => kIsWeb ? false : Platform.environment.containsKey('FLUTTER_TEST');

class PbOfflineCache {

	factory PbOfflineCache(PocketBase pb, String? directoryToSave, {
		Logger? overrideLogger,
		Map<String, List<(String name, bool unique, List<String> columns)>>? indexInstructions,
		Function(bool online)? networkStateListener,
		Function()? localCacheUpdatedListener,
		FutureOr<(String, List<Object?>)?> Function(String tableName, String lastUpdatedTime)? generateWhereForResync,
	}) {

		assert(kIsWeb || directoryToSave != null, "Directory to save to should only be null if building to web.");

		final String? path = directoryToSave == null ? null : join(directoryToSave, "offline_cache");

		return PbOfflineCache._(
			pb,
			makeDb(path),
			overrideLogger ?? Logger(),
			indexInstructions ?? const <String, List<(String name, bool unique, List<String>)>>{},
			networkStateListener,
			path,
			generateWhereForResync,
			localCacheUpdatedListener,
		);
	}

	PbOfflineCache._(this.pb, this.db, this.logger, [this.indexInstructions = const <String, List<(String name, bool unique, List<String>)>>{}, this._networkStateListener, this.dbPath = "", this.generateWhereForResync, this._localCacheUpdatedListener]) {
		db?.execute("""
	CREATE TABLE IF NOT EXISTS _operation_queue (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		operation_type TEXT,
		created INTEGER,
		collection_name TEXT,
		id_to_modify TEXT
	)""");
		db?.execute("""
	CREATE TABLE IF NOT EXISTS _operation_queue_params (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		operation_id INTEGER,
		param_key TEXT,
		param_value TEXT,
		FOREIGN KEY(operation_id) REFERENCES operations(id)
	)""");
		db?.execute("""
	CREATE TABLE IF NOT EXISTS _last_sync_times (
		table_name TEXT PRIMARY KEY,
		last_update TEXT
	)""");

		if (!isTest()) {
			unawaited(_continuouslyCheckDbAccessible());
		}
	}

	factory PbOfflineCache.withDb(PocketBase pb, CommonDatabase db, {Logger? overrideLogger}) {
		return PbOfflineCache._(pb, db, overrideLogger ?? Logger());
	}

	Future<void> dropAllTables(String directoryToSave) async {
		if (db == null) {
			return;
		}
		try {
			final ResultSet tables = db!.select("SELECT name FROM sqlite_master WHERE type = 'table'");

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

				db!.execute('DROP TABLE IF EXISTS $tableName');
				logger.i('Dropped table: $tableName');
			}

			logger.i('All tables dropped successfully');
		} catch (e) {
			logger.w('Error during dropAllTables: $e');
		} finally {
			try {
				db!.execute('VACUUM;');
				logger.i('Database vacuumed successfully');
			} catch (e) {
				logger.w('Error during vacuum: $e');
			}
		}
	}

	String? dbPath;
	bool dbAccessible = true;
	final PocketBase pb;
	CommonDatabase? db;
	final Logger logger;
	final Map<String, List<(String name, bool unique, List<String> columns)>> indexInstructions;
	final Function(bool online)? _networkStateListener;
	final Function()? _localCacheUpdatedListener;

	/// Not required, but recommended. This is called periodically to resync the data with the db
	final FutureOr<(String, List<Object?>)?> Function(String tableName, String lastUpdatedTime)? generateWhereForResync;

	String? get id => isTest() ? "test" : pb.authStore.model?.id;
	bool get tokenValid => pb.authStore.isValid;

	Future<void> tryRefreshAuth() async {
		if (tokenValid && id != null) {
			try {
				await refreshAuth();
			} on ClientException catch (e) {
				if (e.toString().contains("The request requires valid record authorization token to be set")) {
					pb.authStore.clear();
				} else {
					rethrow;
				}
			}
		}
	}

	Future<void> _continuouslyCheckDbAccessible() async {
		if (isTest()) {
			dbAccessible = false;
			return;
		}
		while (true) {
			try {
				final http.Response response = await http.get(pb.buildUrl("/api/health"));
				if (response.statusCode != 200) {
					dbAccessible = false;
				} else {
					if (!dbAccessible) {
						dbAccessible = true;
						logger.i("DB accessible again");
						if (_networkStateListener != null) {
							// Compiler complains if we don't have this null assertion
							// ignore: unnecessary_non_null_assertion
							_networkStateListener!(true);
						}
					}
					await dequeueCachedOperations();
					try {
						if (generateWhereForResync != null && db != null && tableExists(db!, "_last_sync_times")) {
							bool gotNewItems = false;
							final ResultSet syncTimes = db!.select("SELECT * FROM _last_sync_times");
							for (final Row row in syncTimes) {
								final (String, List<Object?>)? whereCondition = await generateWhereForResync!(row["table_name"], row["last_update"]);

								if (whereCondition == null) {
									continue;
								}

								final List<Map<String, dynamic>> items = await getRecords(row["table_name"], where: whereCondition, sort: ("updated", false), source: QuerySource.server);
								if (items.isNotEmpty) {
									gotNewItems = true;
									logger.i("Updating ${items.length} items in table ${row["table_name"]}");
									db!.execute("INSERT OR REPLACE INTO _last_sync_times(table_name, last_update) VALUES(?, ?)", <dynamic>[	row["table_name"], items.last["updated"] ]);
								}
							}
							if (gotNewItems && _localCacheUpdatedListener != null) {
								// Compiler complains if we don't have this null assertion
								// ignore: unnecessary_non_null_assertion
								_localCacheUpdatedListener!();
							}
						}
					} catch (e, stack) {
						logger.e("$e\n\n$stack");
					}
				}
			} catch (_) {
				if (dbAccessible) {
					dbAccessible = false;
					logger.i("DB do longer accessible");
					if (_networkStateListener != null) {
						// ignore: unnecessary_non_null_assertion
						_networkStateListener!(false);
					}
				}
			}
			await Future<void>.delayed(const Duration(seconds: 10));
		}
	}

	Future<void> dequeueCachedOperations() async {

		if (db == null) {
			return;
		}

		final ResultSet data = db!.select("SELECT * FROM _operation_queue ORDER BY created ASC");

		for (final Row operation in data) {
			final String operationId = operation.values[0].toString();
			final String operationType = operation.values[1].toString();
			final String collectionName = operation.values[3].toString();
			final String pbId = operation.values[4].toString();

			final ResultSet data = db!.select("SELECT * FROM _operation_queue_params WHERE operation_id = ?", <String>[ operationId ]);
			final Map<String, dynamic> params = <String, dynamic>{};
			for (final Row operationParam in data) {
				params[operationParam.values[2].toString()] = operationParam.values[3];
			}

			void cleanUp() {
				db!.execute("DELETE FROM _operation_queue WHERE id = ?", <String>[ operationId ]);
				db!.execute("DELETE FROM _operation_queue_params WHERE id = ?", <String>[ operationId ]);
			}

			// If we failed to update data (probably due to a key constraint) then we need to delete the local copy of the record as well or we'll be out of sync
			void deleteLocalRecord() {
				db!.execute("DELETE FROM $collectionName WHERE id = ?", <String>[ pbId ]);
				cleanUp();
			}

			switch (operationType) {
				case "UPDATE":
					try {
						await pb.collection(collectionName).update(pbId, body: params);
						cleanUp();
					} on ClientException catch (e) {
						if (!e.isNetworkError()) {
							logger.e(e, stackTrace: StackTrace.current);
							deleteLocalRecord();
							cleanUp();
						}
					}
					break;
				case "DELETE":
					try {
						await pb.collection(collectionName).delete(pbId);
						cleanUp();
					} on ClientException catch (e) {
						if (!e.isNetworkError()) {
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
						if (!e.isNetworkError()) {
							logger.e("Failed to insert $params into $collectionName ($e)", stackTrace: StackTrace.current);
							deleteLocalRecord();
							cleanUp();
						}
					}
					break;
				default:
					logger.e("Unknown operation type: $operationType, operation: $operation");
			}
		}
	}

	Future<void> refreshAuth() async {
		try {
			await pb.collection('users').authRefresh();
		} on ClientException catch (e) {
			if (!e.isNetworkError()) {
				rethrow;
			}
		}
	}

	void queueOperation(
		String operationType,
		String collectionName,
		{Map<String, dynamic>? values, String idToModify = ""}
	) {

		if (db == null) {
			return;
		}

		// This is not guaranteed to be unique but if two commands are executed at the same time the order doesn't really matter
		final int created = DateTime.now().toUtc().millisecondsSinceEpoch;

		final ResultSet record = db!.select("INSERT INTO _operation_queue (operation_type, created, collection_name, id_to_modify) VALUES ('$operationType', $created, '$collectionName', ?) RETURNING id", <Object>[ idToModify ]);
		final int id = record.first.values.first! as int;

		if (values != null) {
			for (final MapEntry<String, dynamic> entry in values.entries) {

				String valueToWrite;

				if (entry.value is bool) {
					valueToWrite = entry.value.toString();
				} else if (entry.value is int) {
					valueToWrite = entry.value.toString();
				} else if (entry.value is double) {
					valueToWrite = entry.value.toString();
				} else if (entry.value is String) {
					valueToWrite = entry.value.toString();
				} else if (entry.value is List<dynamic> || entry.value is Map<dynamic, dynamic>) {
					valueToWrite = jsonEncode(entry.value);
				} else if (entry.value == null) {
					valueToWrite = "";
				} else {
					valueToWrite = "";
					logger.e("Unknown type: ${entry.value.runtimeType}");
				}

				db!.select("INSERT INTO _operation_queue_params (operation_id, param_key, param_value) VALUES (?, ?, ?)", <Object?>[id, entry.key, valueToWrite]);
			}
		}
	}

	QueryBuilder collection(String collectionName) {
		return QueryBuilder._(this, collectionName, "", <dynamic>[] );
	}
}

extension NetworkErrorCheck on ClientException{
	bool isNetworkError() {
		return toString().contains("refused the network connection")
				|| toString().contains("refused the connection")
				|| toString().contains("Failed host lookup")
				|| toString().contains("No address associated with hostname")
				|| toString().contains("statusCode: 0, response: {}");
	}
}

bool tableExists(CommonDatabase db, String tableName) {
	return db.select(
		"SELECT name FROM sqlite_master WHERE type='table' AND name=?",
		<String> [ tableName ],
	).isNotEmpty;
}

ResultSet selectBuilder(CommonDatabase db, String tableName, {
	String? columns,
	(String, List<Object?>)? filter,
	int? maxItems,
	(String, bool descending)? sort,
	Map<String, dynamic>? startAfter,
}) {

	final StringBuffer query = StringBuffer("SELECT ${columns ?? "*"} FROM $tableName");

	(String, List<dynamic> newValues) generateSortCondition(Map<String, dynamic>? startAfter, (String, bool descending)? sort, bool and, List<dynamic> parameters) {

		if (startAfter == null || startAfter.isEmpty) {
			return ("", parameters);
		}

		assert(sort != null, "Start after requires a sort condition");

		if (sort == null) {
			return ("", parameters);
		}

		final Map<String, dynamic> relevantStartKeys = <String, dynamic>{};

		if (startAfter.containsKey(sort.$1)) {
			relevantStartKeys[sort.$1] = startAfter[sort.$1];
		}

		assert(relevantStartKeys.isNotEmpty, "Unable to find sort key in sort!");
		if (relevantStartKeys.isEmpty) {
			return ("", <dynamic>[]);
		}

		if (!relevantStartKeys.containsKey("id")) {
			relevantStartKeys["id"] = startAfter["id"];
		}

		final List<String> keys = relevantStartKeys.keys.toList();
		final List<dynamic> values = relevantStartKeys.values.toList();

		final String keysPart = keys.join(', ');
		final String valuesPart = values.map((dynamic val) {
			return "?";
		}).join(', ');

		return ("${and ? " AND " : ""}($keysPart) ${sort.$2 ? "<" : ">"} ($valuesPart)", List<dynamic>.from(parameters)..addAll(values));
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

		final (String whereClause, List<dynamic> items) orderBy = generateSortCondition(startAfter, sort, true, filter.$2);

		query.write(" WHERE ${preprocessQuery(filter.$1, filter.$2)}${orderBy.$1}");
		filter = (filter.$1, orderBy.$2);

	} else if (startAfter != null) {

		final (String whereClause, List<dynamic> items) orderBy = generateSortCondition(startAfter, sort, true, <dynamic>[]);

		query.write(" WHERE ${generateSortCondition(startAfter, sort, false, <dynamic>[])}");
		filter = ("", orderBy.$2);
	}

	if (sort != null) {
		query.write(" ORDER BY ${sort.$1} ${sort.$2 ? "DESC" : "ASC"}");
	}

	if (maxItems != null) {
		query.write(" LIMIT $maxItems");
	}

	query.write(";");

	if (filter != null) {

		for (int i = 0; i < filter.$2.length; i++) {
			if (filter.$2[i] is DateTime) {
				filter.$2[i] = (filter.$2[i] as DateTime?)?.toUtc().toString();
			} else if (filter.$2[i] is List<dynamic> || filter.$2[i] is Map<dynamic, dynamic>) {
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
