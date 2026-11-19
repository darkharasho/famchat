import 'package:material_ui/material_ui.dart';

import '../../landlord/landlord.dart';
import '../../rules.dart';

/// [n] dollars with thousands separators: `$1,350`.
String money(int n) {
  final digits = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-\$' : '\$');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return b.toString();
}

String _space(int? i) => i == null ? '?' : landlordSpaces[i].name;

/// One event as a log line, with [names] (first, second) as shown ("You" for
/// the viewer): "Mom rolled 4+3 → Iris Place", "You paid Mom $14 rent".
String landlordLog(LandlordEvent e, (String, String) names) {
  String name(Side s) => s == Side.first ? names.$1 : names.$2;
  final a = name(e.actor);
  final you = a == 'You';
  // The other party, as an object: "you", "Mom" or "the bank".
  final o = e.other;
  final them = o == null ? 'the bank' : (name(o) == 'You' ? 'you' : name(o));
  final n = money(e.amount ?? 0);
  final sp = _space(e.space);
  final d = e.dice;
  return switch (e.kind) {
    LandlordEventKind.rolled => '$a rolled ${d?.$1}+${d?.$2} → $sp',
    LandlordEventKind.passedStart => '$a passed Start and collected $n',
    LandlordEventKind.bought => '$a bought $sp for $n',
    LandlordEventKind.declined => '$a passed on $sp',
    LandlordEventKind.rent => '$a paid $them $n rent',
    LandlordEventKind.tax => '$a paid $n $sp',
    LandlordEventKind.drew => '$a drew ${e.card?.deck.title}: ${e.card?.text}',
    LandlordEventKind.paid => o == null ? '$a paid $n' : '$a paid $them $n',
    LandlordEventKind.collected => o == null ? '$a collected $n' : '$a collected $n from $them',
    LandlordEventKind.jailed => '$a went to jail',
    LandlordEventKind.bail => '$a paid $n to leave jail',
    LandlordEventKind.usedCard => '$a used a get out of jail free card',
    LandlordEventKind.leftJail => '$a rolled ${d?.$1}+${d?.$2} and left jail',
    LandlordEventKind.built => '$a built on $sp',
    LandlordEventKind.sold => '$a sold a building on $sp for $n',
    LandlordEventKind.mortgaged => '$a mortgaged $sp for $n',
    LandlordEventKind.unmortgaged => '$a paid $n to unmortgage $sp',
    LandlordEventKind.offered => '$a offered a trade',
    LandlordEventKind.accepted => 'Trade accepted',
    LandlordEventKind.rejected => 'Trade rejected',
    LandlordEventKind.interest => '$a paid $n interest on $sp',
    LandlordEventKind.owes => '$a ${you ? 'owe' : 'owes'} $them $n',
    LandlordEventKind.debtPaid => '$a paid off $n',
    LandlordEventKind.bankrupt => '$a went bankrupt',
    LandlordEventKind.endTurn => '$a ended the turn',
  };
}

/// The icon for event [e] in the log.
IconData landlordLogIcon(LandlordEvent e) => switch (e.kind) {
  LandlordEventKind.rolled => Icons.casino_outlined,
  LandlordEventKind.passedStart => Icons.flag_outlined,
  LandlordEventKind.bought => Icons.home_work_outlined,
  LandlordEventKind.declined => Icons.do_not_disturb_on_outlined,
  LandlordEventKind.rent => Icons.key_outlined,
  LandlordEventKind.tax => Icons.account_balance_outlined,
  LandlordEventKind.drew => landlordDeckIcon(e.card?.deck ?? LandlordDeck.luck),
  LandlordEventKind.paid => Icons.remove_circle_outline,
  LandlordEventKind.collected => Icons.add_circle_outline,
  LandlordEventKind.jailed => Icons.lock_outline,
  LandlordEventKind.bail || LandlordEventKind.leftJail => Icons.lock_open_outlined,
  LandlordEventKind.usedCard => Icons.confirmation_number_outlined,
  LandlordEventKind.built => Icons.house_outlined,
  LandlordEventKind.sold => Icons.sell_outlined,
  LandlordEventKind.mortgaged => Icons.request_quote_outlined,
  LandlordEventKind.unmortgaged => Icons.check_circle_outline,
  LandlordEventKind.offered => Icons.swap_horiz,
  LandlordEventKind.accepted => Icons.handshake_outlined,
  LandlordEventKind.rejected => Icons.block,
  LandlordEventKind.interest => Icons.percent,
  LandlordEventKind.owes => Icons.warning_amber_rounded,
  LandlordEventKind.debtPaid => Icons.task_alt,
  LandlordEventKind.bankrupt => Icons.money_off,
  LandlordEventKind.endTurn => Icons.skip_next_outlined,
};

/// The icon of a card deck: a sparkle for Luck, a piggy bank for Family Fund.
IconData landlordDeckIcon(LandlordDeck d) => switch (d) {
  LandlordDeck.luck => Icons.auto_awesome,
  LandlordDeck.fund => Icons.savings_outlined,
};

/// The events after [me]'s last one (all of them if I have none): what
/// happened while I was away.
List<LandlordEvent> sinceMyLast(List<LandlordEvent> events, Side me) {
  final last = events.lastIndexWhere((e) => e.actor == me);
  return events.sublist(last + 1);
}
