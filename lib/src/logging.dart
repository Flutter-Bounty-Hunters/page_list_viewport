// ignore_for_file: avoid_print
library logging;

import 'package:logging/logging.dart' as logging;

class LogNames {
  static const pagesList = 'pdf.pagesList';
  static const pagesListController = 'pdf.pagesList.controller';
  static const pagesListGestures = 'pdf.pagesList.gestures';
}

class PageListViewportLogs {
  static final pagesList = logging.Logger(LogNames.pagesList);
  static final pagesListController = logging.Logger(LogNames.pagesListController);
  static final pagesListGestures = logging.Logger(LogNames.pagesListGestures);

  static final _activeLoggers = <logging.Logger>{};

  static void initAllLogs(logging.Level level) {
    initLoggers(level, {logging.Logger.root});
  }

  static void initLoggers(logging.Level level, Set<logging.Logger> loggers) {
    logging.hierarchicalLoggingEnabled = true;

    for (final logger in loggers) {
      if (!_activeLoggers.contains(logger)) {
        print('Initializing logger: ${logger.name}');
        logger
          ..level = level
          ..onRecord.listen(printLog);

        _activeLoggers.add(logger);
      }
    }
  }

  static void deactivateLoggers(Set<logging.Logger> loggers) {
    for (final logger in loggers) {
      if (_activeLoggers.contains(logger)) {
        print('Deactivating logger: ${logger.name}');
        logger.clearListeners();

        _activeLoggers.remove(logger);
      }
    }
  }

  static void printLog(logging.LogRecord record) {
    // print(
    //     '(${record.time.second}.${record.time.millisecond.toString().padLeft(3, '0')}) ${record.loggerName} > ${record.level.name}: ${record.message}');
    print('${record.loggerName} > ${record.level.name}: ${record.message}');
  }
}
