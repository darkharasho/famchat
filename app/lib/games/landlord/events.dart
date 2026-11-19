import 'package:flutter/foundation.dart';

import '../rules.dart';
import 'cards.dart';

enum LandlordEventKind {
  rolled,
  passedStart,
  bought,
  declined,
  bid,
  passed,
  auctionWon,
  auctionUnsold,
  rent,
  tax,
  drew,
  paid,
  collected,
  jailed,
  bail,
  usedCard,
  leftJail,
  built,
  sold,
  mortgaged,
  unmortgaged,
  offered,
  accepted,
  rejected,
  interest,
  owes,
  debtPaid,
  bankrupt,
  endTurn,
}

/// One public thing that happened in a Landlord game. [other] is the player
/// paid or paying [actor]; null means the bank.
@immutable
class LandlordEvent {
  const LandlordEvent(
    this.actor,
    this.kind, {
    this.space,
    this.amount,
    this.dice,
    this.card,
    this.other,
  });

  final Side actor;
  final LandlordEventKind kind;
  final int? space, amount;
  final (int, int)? dice;
  final LandlordCard? card;
  final Side? other;
}
