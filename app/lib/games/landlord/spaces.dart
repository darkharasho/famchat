import 'dart:ui' show Color;

import 'cards.dart';

/// What a Landlord space does when you land on it.
enum SpaceKind { start, property, station, utility, card, tax, jail, rest, goToJail }

/// A set of spaces owned together. The eight colour groups can be built on.
enum LandlordGroup {
  brown(Color(0xFF8B5A2B)),
  lightBlue(Color(0xFF9FD3F0)),
  pink(Color(0xFFD94F9B)),
  orange(Color(0xFFF39237)),
  red(Color(0xFFE03C31)),
  yellow(Color(0xFFF5D547)),
  green(Color(0xFF2E9E5B)),
  darkBlue(Color(0xFF2B4FA8)),
  station(Color(0xFF616161)),
  utility(Color(0xFF616161));

  const LandlordGroup(this.color);

  final Color color;

  bool get buildable => this != station && this != utility;
}

/// One of the 40 spaces. Permanent wire format: indexes, prices and rents
/// (docs/superpowers/specs/2026-11-18-go-fish-and-landlord-design.md).
class LandlordSpace {
  const LandlordSpace(
    this.index,
    this.name,
    this.kind, {
    this.group,
    this.price = 0,
    this.houseCost = 0,
    this.rent = const [],
    this.tax = 0,
    this.deck,
  });

  final int index;
  final String name;
  final SpaceKind kind;
  final LandlordGroup? group;
  final int price, houseCost, tax;

  /// Colour properties: base, 1–4 houses, hotel. Empty otherwise.
  final List<int> rent;

  /// Card spaces: which deck.
  final LandlordDeck? deck;

  /// Whether it can be owned.
  bool get ownable => group != null;

  int get mortgageValue => price ~/ 2;
}

const _b = LandlordGroup.brown, _lb = LandlordGroup.lightBlue;
const _pk = LandlordGroup.pink, _or = LandlordGroup.orange;
const _rd = LandlordGroup.red, _ye = LandlordGroup.yellow;
const _gr = LandlordGroup.green, _db = LandlordGroup.darkBlue;

LandlordSpace _p(int i, String n, LandlordGroup g, int price, int house, List<int> rent) =>
    LandlordSpace(i, n, SpaceKind.property, group: g, price: price, houseCost: house, rent: rent);

LandlordSpace _st(int i, String n) =>
    LandlordSpace(i, n, SpaceKind.station, group: LandlordGroup.station, price: 200);

LandlordSpace _ut(int i, String n) =>
    LandlordSpace(i, n, SpaceKind.utility, group: LandlordGroup.utility, price: 150);

LandlordSpace _luck(int i) => LandlordSpace(i, 'Luck', SpaceKind.card, deck: LandlordDeck.luck);

LandlordSpace _fund(int i) =>
    LandlordSpace(i, 'Family Fund', SpaceKind.card, deck: LandlordDeck.fund);

/// The board, clockwise from Start.
final List<LandlordSpace> landlordSpaces = List.unmodifiable([
  const LandlordSpace(0, 'Start', SpaceKind.start),
  _p(1, 'Acorn Lane', _b, 60, 50, const [2, 10, 30, 90, 160, 250]),
  _fund(2),
  _p(3, 'Birch Row', _b, 60, 50, const [4, 20, 60, 180, 320, 450]),
  const LandlordSpace(4, 'Income Tax', SpaceKind.tax, tax: 200),
  _st(5, 'South Station'),
  _p(6, 'Cedar Street', _lb, 100, 50, const [6, 30, 90, 270, 400, 550]),
  _luck(7),
  _p(8, 'Daisy Avenue', _lb, 100, 50, const [6, 30, 90, 270, 400, 550]),
  _p(9, 'Elm Walk', _lb, 120, 50, const [8, 40, 100, 300, 450, 600]),
  const LandlordSpace(10, 'Jail', SpaceKind.jail),
  _p(11, 'Fern Court', _pk, 140, 100, const [10, 50, 150, 450, 625, 750]),
  _ut(12, 'Power Grid'),
  _p(13, 'Garden Road', _pk, 140, 100, const [10, 50, 150, 450, 625, 750]),
  _p(14, 'Hazel Way', _pk, 160, 100, const [12, 60, 180, 500, 700, 900]),
  _st(15, 'West Station'),
  _p(16, 'Iris Place', _or, 180, 100, const [14, 70, 200, 550, 750, 950]),
  _fund(17),
  _p(18, 'Juniper Road', _or, 180, 100, const [14, 70, 200, 550, 750, 950]),
  _p(19, 'Kestrel Avenue', _or, 200, 100, const [16, 80, 220, 600, 800, 1000]),
  const LandlordSpace(20, 'Rest Stop', SpaceKind.rest),
  _p(21, 'Linden Square', _rd, 220, 150, const [18, 90, 250, 700, 875, 1050]),
  _luck(22),
  _p(23, 'Maple Avenue', _rd, 220, 150, const [18, 90, 250, 700, 875, 1050]),
  _p(24, 'Nettle Street', _rd, 240, 150, const [20, 100, 300, 750, 925, 1100]),
  _st(25, 'North Station'),
  _p(26, 'Oak Terrace', _ye, 260, 150, const [22, 110, 330, 800, 975, 1150]),
  _p(27, 'Poplar Road', _ye, 260, 150, const [22, 110, 330, 800, 975, 1150]),
  _ut(28, 'Reservoir'),
  _p(29, 'Quarry Hill', _ye, 280, 150, const [24, 120, 360, 850, 1025, 1200]),
  const LandlordSpace(30, 'Go to Jail', SpaceKind.goToJail),
  _p(31, 'Rowan Park', _gr, 300, 200, const [26, 130, 390, 900, 1100, 1275]),
  _p(32, 'Spruce Drive', _gr, 300, 200, const [26, 130, 390, 900, 1100, 1275]),
  _fund(33),
  _p(34, 'Thistle Way', _gr, 320, 200, const [28, 150, 450, 1000, 1200, 1400]),
  _st(35, 'East Station'),
  _luck(36),
  _p(37, 'Upper Willow', _db, 350, 200, const [35, 175, 500, 1100, 1300, 1500]),
  const LandlordSpace(38, 'Luxury Tax', SpaceKind.tax, tax: 100),
  _p(39, 'Vista Heights', _db, 400, 200, const [50, 200, 600, 1400, 1700, 2000]),
]);

final Map<LandlordGroup, List<int>> _groups = {
  for (final g in LandlordGroup.values)
    g: List.unmodifiable([
      for (final s in landlordSpaces)
        if (s.group == g) s.index,
    ]),
};

/// The spaces of [g], in board order.
List<int> groupSpaces(LandlordGroup g) => _groups[g]!;
