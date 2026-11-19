import 'package:famchat/games/go_fish.dart';
import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wireInt accepts ints and integral finite doubles only', () {
    expect(wireInt(3), 3);
    expect(wireInt(-2), -2);
    expect(wireInt(3.0), 3);
    expect(wireInt(-0.0), 0);
    expect(wireInt(3.5), isNull);
    expect(wireInt(double.nan), isNull);
    expect(wireInt(double.infinity), isNull);
    expect(wireInt(1e300), isNull);
    expect(wireInt('3'), isNull);
    expect(wireInt(null), isNull);
    expect(wireInt(true), isNull);
  });

  test('initialBoard deals Go Fish from the seed', () {
    final b = initialBoard(GameType.gofish, 1) as GoFishBoard;
    expect(b.hand(Side.first), GoFishBoard.deal(1).hand(Side.first));
    expect(GameType.gofish.seeded, isTrue);
    expect(GameType.chess.seeded, isFalse);
    expect(GameType.fromWire('gofish'), GameType.gofish);
    expect(GameType.gofish.title, 'Go Fish');
  });

  test('Landlord: seeded, long, set up from the seed', () {
    expect(GameType.fromWire('landlord'), GameType.landlord);
    expect(GameType.landlord.title, 'Landlord');
    expect(GameType.landlord.seeded, isTrue);
    expect([for (final t in GameType.values) if (t.long) t], [GameType.landlord]);
    final b = initialBoard(GameType.landlord, 7) as LandlordBoard;
    final s = LandlordBoard.setup(7);
    for (final d in LandlordDeck.values) {
      expect(b.deck(d), s.deck(d));
    }
  });
}
