import 'package:chess/chess.dart' as ch;
import 'package:meta/meta.dart';

import 'rules.dart';

enum ChessRole { king, queen, rook, bishop, knight, pawn }

class ChessPieceAt {
  const ChessPieceAt(this.side, this.role);

  final Side side;
  final ChessRole role;
}

final _square = RegExp(r'^[a-h][1-8]$');
final _uci = RegExp(r'^([a-h][1-8])([a-h][1-8])([qrbn]?)$');

const _roles = {
  'k': ChessRole.king,
  'q': ChessRole.queen,
  'r': ChessRole.rook,
  'b': ChessRole.bishop,
  'n': ChessRole.knight,
  'p': ChessRole.pawn,
};

/// Standard chess on the `chess` package. First is white. Move:
/// `{"uci": "e2e4"}`; a promotion carries a lowercase suffix (`e7e8q`, one of
/// `q r b n`), which is required on promotions and rejected otherwise, so
/// every move has exactly one encoding.
///
/// Each board owns its own [ch.Chess] with the full move history (needed for
/// threefold repetition). The package mutates pieces and history entries
/// while checking repetition, so boards never share that state.
class ChessBoard implements Board {
  ChessBoard._(this._chess, this.lastMove);

  factory ChessBoard.initial() => ChessBoard._(ch.Chess(), null);

  /// [fen] must be valid; the package prints on invalid input.
  @visibleForTesting
  factory ChessBoard.fromFen(String fen) =>
      ChessBoard._(ch.Chess.fromFEN(fen), null);

  final ch.Chess _chess;

  /// The (from, to) squares of the move that produced this board; null on a
  /// fresh board.
  final (String, String)? lastMove;

  @override
  Side get toMove => _chess.turn == ch.Color.WHITE ? Side.first : Side.second;

  @override
  bool get drawOffers => true;

  bool get inCheck => _chess.in_check;

  /// The piece on [square] (e.g. 'e4'), or null if empty or not a square.
  ChessPieceAt? at(String square) {
    if (!_square.hasMatch(square)) return null;
    final p = _chess.get(square);
    if (p == null) return null;
    return ChessPieceAt(
      p.color == ch.Color.WHITE ? Side.first : Side.second,
      _roles[p.type.name]!,
    );
  }

  List<ch.Move> _movesFrom(String square) {
    if (!_square.hasMatch(square)) return const [];
    return _chess.generate_moves({'square': square});
  }

  /// Legal destination squares for the piece on [square], in the package's
  /// generation order, each listed once. Empty unless [square] holds a piece
  /// of the side to move.
  List<String> targetsFrom(String square) => [
    ...{for (final m in _movesFrom(square)) m.toAlgebraic},
  ];

  /// Whether moving [from] to [to] is a legal promotion (needs a suffix).
  bool needsPromotion(String from, String to) =>
      _movesFrom(from).any((m) => m.toAlgebraic == to && m.promotion != null);

  /// Like [ch.Chess.copy], but also copies the pieces and the history
  /// entries' castling and king maps. The package's `undo_move` (run by
  /// `in_threefold_repetition` and legal-move generation) rewrites piece
  /// types and replays moves onto restored history maps; with the shallow
  /// `copy()` that corrupts other boards sharing them (a promoted queen
  /// turning back into a pawn, castling rights vanishing).
  static ch.Chess _clone(ch.Chess c) => ch.Chess()
    ..board = [
      for (final p in c.board) p == null ? null : ch.Piece(p.type, p.color),
    ]
    ..kings = ch.ColorMap<int>.clone(c.kings)
    ..turn = c.turn
    ..castling = ch.ColorMap<int>.clone(c.castling)
    ..ep_square = c.ep_square
    ..half_moves = c.half_moves
    ..move_number = c.move_number
    ..history = [
      for (final s in c.history)
        ch.State(
          s.move,
          ch.ColorMap<int>.clone(s.kings),
          s.turn,
          ch.ColorMap<int>.clone(s.castling),
          s.ep_square,
          s.half_moves,
          s.move_number,
        ),
    ]
    ..header = Map.of(c.header);

  @override
  late final Outcome? outcome = _computeOutcome();

  Outcome? _computeOutcome() {
    final noMoves = _chess.generate_moves().isEmpty;
    if (noMoves) {
      return _chess.in_check
          ? Outcome(toMove.other, 'checkmate')
          : const Outcome(null, 'stalemate');
    }
    if (_chess.insufficient_material) {
      return const Outcome(null, 'insufficient');
    }
    if (_chess.in_threefold_repetition) {
      return const Outcome(null, 'threefold');
    }
    // The one `in_draw` condition not already checked above (the package's
    // 50-move rule), without repeating the costly repetition scan.
    if (_chess.half_moves >= 100) return const Outcome(null, 'fifty_moves');
    return null;
  }

  @override
  ChessBoard? play(Map<String, Object?> move) {
    final uci = move['uci'];
    if (uci is! String) return null;
    final m = _uci.firstMatch(uci);
    if (m == null) return null;
    final from = m.group(1)!, to = m.group(2)!, promo = m.group(3)!;
    if (needsPromotion(from, to) != promo.isNotEmpty) return null;
    final next = _clone(_chess);
    final ok = next.move({
      'from': from,
      'to': to,
      if (promo.isNotEmpty) 'promotion': promo,
    });
    return ok ? ChessBoard._(next, (from, to)) : null;
  }
}
