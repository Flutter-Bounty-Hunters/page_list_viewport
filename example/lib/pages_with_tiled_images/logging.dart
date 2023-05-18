// ignore_for_file: avoid_print
library logging;

import 'package:logging/logging.dart' as logging;

class ImageTileLogNames {
  static const imageTiles = 'imageTiles';
  static const page = '$imageTiles.page';
  static const pageLayout = '$page.layout';
  static const pagePainting = '$page.painting';
  static const thumbnail = '$imageTiles.thumbnail';
  static const tiles = '$imageTiles.tiles';
  static const tilesCache = '$tiles.cache';
  static const tile = '$tiles.tile';
  static const tilePreparer = '$tile.preparer';
  static const tilePipeline = '$tile.pipeline';
  static const tileDisplay = '$tile.display';
  static const memoryUsage = 'memory_usage';
}

class ImageTileLogs {
  static final imageTiles = logging.Logger(ImageTileLogNames.imageTiles);
  static final page = logging.Logger(ImageTileLogNames.page);
  static final pageLayout = logging.Logger(ImageTileLogNames.pageLayout);
  static final pagePainting = logging.Logger(ImageTileLogNames.pagePainting);
  static final thumbnail = logging.Logger(ImageTileLogNames.thumbnail);
  static final tiles = logging.Logger(ImageTileLogNames.tiles);
  static final tilesCache = logging.Logger(ImageTileLogNames.tilesCache);
  static final tile = logging.Logger(ImageTileLogNames.tile);
  static final tilePreparer = logging.Logger(ImageTileLogNames.tilePreparer);
  static final tilePipeline = logging.Logger(ImageTileLogNames.tilePipeline);
  static final tileDisplay = logging.Logger(ImageTileLogNames.tileDisplay);
  static final memoryUsage = logging.Logger(ImageTileLogNames.memoryUsage);

  static final _activeLoggers = <logging.Logger>{};

  /// Configures all loggers to output logs at the given [level].
  static void initAllLogs(logging.Level level) {
    initLoggers(level, {logging.Logger.root});
  }

  /// Configures only the specified [loggers] to output logs at the given [level].
  static void initLoggers(logging.Level level, Set<logging.Logger> loggers) {
    logging.hierarchicalLoggingEnabled = true;

    for (final logger in loggers) {
      if (!_activeLoggers.contains(logger)) {
        print('Initializing logger: ${logger.name}');
        logger
          ..level = level
          ..onRecord.listen(_printLog);

        _activeLoggers.add(logger);
      }
    }
  }

  /// Stops the given [loggers] from outputting any logs.
  static void deactivateLoggers(Set<logging.Logger> loggers) {
    for (final logger in loggers) {
      if (_activeLoggers.contains(logger)) {
        print('Deactivating logger: ${logger.name}');
        logger.clearListeners();

        _activeLoggers.remove(logger);
      }
    }
  }

  static void _printLog(logging.LogRecord record) {
    print('${record.loggerName} > ${record.level.name}: ${record.message}');
  }
}
