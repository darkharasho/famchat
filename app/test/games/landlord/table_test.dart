import 'package:famchat/games/landlord/cards.dart';
import 'package:famchat/games/landlord/spaces.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('40 spaces with the spec table values', () {
    expect(landlordSpaces, hasLength(40));
    for (var i = 0; i < 40; i++) {
      expect(landlordSpaces[i].index, i);
    }
    final a = landlordSpaces[1];
    expect((a.price, a.houseCost), (60, 50));
    expect(a.rent, [2, 10, 30, 90, 160, 250]);
    final z = landlordSpaces[39];
    expect((z.price, z.houseCost), (400, 200));
    expect(z.rent, [50, 200, 600, 1400, 1700, 2000]);
    for (final i in [5, 15, 25, 35]) {
      expect((landlordSpaces[i].kind, landlordSpaces[i].price), (SpaceKind.station, 200));
    }
    for (final i in [12, 28]) {
      expect((landlordSpaces[i].kind, landlordSpaces[i].price), (SpaceKind.utility, 150));
    }
    expect(landlordSpaces[4].tax, 200);
    expect(landlordSpaces[38].tax, 100);
    for (final i in [2, 17, 33]) {
      expect(landlordSpaces[i].deck, LandlordDeck.fund);
    }
    for (final i in [7, 22, 36]) {
      expect(landlordSpaces[i].deck, LandlordDeck.luck);
    }
    expect(landlordSpaces[10].kind, SpaceKind.jail);
    expect(landlordSpaces[30].kind, SpaceKind.goToJail);
  });

  test('groups', () {
    expect(groupSpaces(LandlordGroup.darkBlue), [37, 39]);
    expect(groupSpaces(LandlordGroup.brown), [1, 3]);
    expect(groupSpaces(LandlordGroup.station), [5, 15, 25, 35]);
    expect(groupSpaces(LandlordGroup.utility), [12, 28]);
    var owned = 0;
    for (final g in LandlordGroup.values) {
      owned += groupSpaces(g).length;
    }
    expect(owned, 28);
  });

  test('cards: 32 in two decks, jail-free at 7 and 20', () {
    expect(LandlordCard.values, hasLength(32));
    for (final c in LandlordCard.values) {
      expect(c.deck, c.index < 16 ? LandlordDeck.luck : LandlordDeck.fund);
    }
    expect([for (final c in LandlordCard.values) if (c.jailFree) c.index], [7, 20]);
  });

  test('no trademarked names', () {
    const banned = [
      'monopoly', 'chance', 'community chest', 'free parking', 'boardwalk', //
      'park place', 'water works', 'electric company', 'pass go',
    ];
    final texts = [
      for (final s in landlordSpaces) s.name,
      for (final c in LandlordCard.values) c.text,
    ];
    for (final t in texts) {
      for (final b in banned) {
        expect(t.toLowerCase().contains(b), isFalse, reason: '"$t" contains "$b"');
      }
    }
  });
}
