import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'logging.dart';

/// Uniquely identifies a tile within a document.
///
/// A [PageTileIndex] combines a specific page index, with an index for a tile
/// within that page.
class PageTileIndex {
  const PageTileIndex(this.pageIndex, this.tileIndex);

  final int pageIndex;
  final TileIndex tileIndex;

  @override
  String toString() => "[PageTileIndex] - page: $pageIndex, tile: $tileIndex";

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PageTileIndex &&
          runtimeType == other.runtimeType &&
          pageIndex == other.pageIndex &&
          tileIndex == other.tileIndex;

  @override
  int get hashCode => pageIndex.hashCode ^ tileIndex.hashCode;
}

/// Uniquely identifies a tile within a page.
///
/// A tile is defined by its row and column position, as well as its level of
/// subdivision. Pages have layers of tiles, where each new layer has more tiles
/// than the last, e.g., 1, 4, 8, 16, etc.
class TileIndex {
  const TileIndex({
    required this.row,
    required this.col,
    required this.level,
    required this.subdivisionBase,
  });

  final int row;
  final int col;
  final int level;

  /// The number of segments by which to divide one side of a tile to create
  /// tile subdivisions.
  ///
  /// Example: a value of `2` will divide each side of each by tile into two,
  /// resulting in subdivisions of 1x1, 2x2, 4x4, 8x8, etc.
  final int subdivisionBase;

  Rect get pageRegion {
    final pageFraction = 1 / pow(subdivisionBase, level);
    return Rect.fromLTWH(
      col * pageFraction,
      row * pageFraction,
      pageFraction,
      pageFraction,
    );
  }

  @override
  String toString() => "[TileIndex] - ($col, $row), level: $level, base: $subdivisionBase";

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TileIndex &&
          runtimeType == other.runtimeType &&
          row == other.row &&
          col == other.col &&
          level == other.level &&
          subdivisionBase == other.subdivisionBase;

  @override
  int get hashCode => row.hashCode ^ col.hashCode ^ level.hashCode ^ subdivisionBase.hashCode;
}

/// A pre-generated set of tiles at the given number of [levels], dividing each tile
/// side by the given [subdivisionBase], e.g., base of `2` yields 1x1, 2x2, 4x4, 8x4, etc.
///
/// The time it takes to generate tiles beyond 3-4 levels is non-trivial. You should run
/// such a constructor as little as possible, and in places where you can afford a brief
/// hiccup.
///
/// If it turns out that tile generation must happen in a completely non-jank manner, then
/// we should move tile generation into an `async` `init()` function, instead of doing it
/// recursively in the constructor.
class SubdividingTileSet {
  SubdividingTileSet({
    required this.levels,
    this.subdivisionBase = 2,
  })  : assert(levels >= 1),
        assert(subdivisionBase >= 2) {
    _root = TileSubdivision(
      index: TileIndex(
        row: 0,
        col: 0,
        level: 0,
        subdivisionBase: subdivisionBase,
      ),
      levelsRemaining: levels - 1,
    );
  }

  late final TileSubdivision _root;

  final int levels;

  /// The number of segments by which to divide one side of a tile to create
  /// tile subdivisions.
  ///
  /// Example: a value of `2` will divide each side of each by tile into two,
  /// resulting in subdivisions of 1x1, 2x2, 4x4, 8x8, etc.
  final int subdivisionBase;

  void visitBreadthFirst(
    TileVisitor visitor, {
    int minLevel = 0,
    int? maxLevel,
    Rect? cullingViewport,
  }) {
    // TODO: only add child visitors if desired
    int tileInspectionCount = 0;
    int tileVisitCount = 0;

    final queue = [_root];

    while (queue.isNotEmpty) {
      tileInspectionCount += 1;
      final tile = queue.removeAt(0);

      if (tile.index.level >= minLevel) {
        tileVisitCount += 1;
        visitor(tile);
      }

      if (tile.hasChildren && (maxLevel == null || tile.index.level < maxLevel)) {
        for (final row in tile._childTiles) {
          for (final child in row) {
            if (cullingViewport == null || child.index.pageRegion.overlaps(cullingViewport)) {
              queue.add(child);
            }
          }
        }
      }
    }

    ImageTileLogs.tiles.finer("Tile set breadth first - inspection: $tileInspectionCount, visited: $tileVisitCount");
  }

  void visitDepthFirst(TileVisitor visitor, [int? maxLevel]) {
    _visitTileDepthFirst(visitor, _root, maxLevel);
  }

  void _visitTileDepthFirst(TileVisitor visitor, TileSubdivision tile, [int? maxLevel]) {
    visitor(tile);

    if (tile.hasChildren && (maxLevel == null || tile.index.level < maxLevel)) {
      for (final row in tile._childTiles) {
        for (final child in row) {
          _visitTileDepthFirst(visitor, child);
        }
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubdividingTileSet &&
          runtimeType == other.runtimeType &&
          levels == other.levels &&
          subdivisionBase == other.subdivisionBase;

  @override
  int get hashCode => levels.hashCode ^ subdivisionBase.hashCode;
}

typedef TileVisitor = void Function(TileSubdivision tile);

class TileSubdivision {
  TileSubdivision({
    required this.index,
    required int levelsRemaining,
  }) : assert(levelsRemaining >= 0) {
    _generateChildTiles(levelsRemaining);
  }

  void _generateChildTiles(int levelsRemaining) {
    if (levelsRemaining > 0) {
      final subdivisionPerDimension = index.subdivisionBase;

      _childTiles = List.generate(
        subdivisionPerDimension,
        (row) => List.generate(
          subdivisionPerDimension,
          (col) {
            // Explanation of row/col calculation:
            //
            // We calculate our children's row/col in relation to our row/col. Moving from our
            // level to our child's level, the same space gets subdivided into
            // subdivisionBase^subdivisionDegree * subdivisionBase^subdivisionDegree more tiles.
            // Therefore, our child's row index is the same as ours, except multiplied by
            // subdivisionBase^subdivisionDegree. Then, we add the row offset of this particular
            // child tile within this tile.
            final childGlobalRow = (index.row * index.subdivisionBase) + row;
            final childGlobalCol = (index.col * index.subdivisionBase) + col;

            return TileSubdivision(
              index: TileIndex(
                row: childGlobalRow,
                col: childGlobalCol,
                level: index.level + 1,
                subdivisionBase: index.subdivisionBase,
              ),
              levelsRemaining: levelsRemaining - 1,
            );
          },
        ),
      );
    } else {
      _childTiles = [<TileSubdivision>[]];
    }
  }

  final TileIndex index;

  bool get hasChildren => _childTiles.isNotEmpty;

  /// Child tiles ordered by column, e.g., `_childTiles[row][col]`.
  late final List<List<TileSubdivision>> _childTiles;

  @override
  String toString() => "[TileSubdivision] - index: $index";
}
