/// The two Landlord card decks.
enum LandlordDeck {
  luck('Luck'),
  fund('Family Fund');

  const LandlordDeck(this.title);

  final String title;
}

/// Every card, in the pre-shuffle order of the spec: Luck is ids 0–15,
/// Family Fund 16–31 (the id is the [index]). Permanent wire format.
enum LandlordCard {
  // Luck.
  luckToStart(LandlordDeck.luck, 'Advance to Start'),
  luckToNettle(LandlordDeck.luck, 'Advance to Nettle Street'),
  luckToFern(LandlordDeck.luck, 'Advance to Fern Court'),
  luckToUtility(LandlordDeck.luck, 'Advance to the nearest utility. If it is owned, pay 10× a fresh roll'),
  luckToStationA(LandlordDeck.luck, 'Advance to the nearest station. If it is owned, pay double rent'),
  luckToStationB(LandlordDeck.luck, 'Advance to the nearest station. If it is owned, pay double rent'),
  luckCollect50(LandlordDeck.luck, 'Your side hustle pays off: collect \$50'),
  luckJailFree(LandlordDeck.luck, 'Get out of jail free. Keep this card until needed'),
  luckBack3(LandlordDeck.luck, 'Go back 3 spaces'),
  luckToJail(LandlordDeck.luck, "Off to jail! You don't collect \$200"),
  luckRepairs(LandlordDeck.luck, 'The boiler broke: pay \$25 per house and \$100 per hotel'),
  luckPay15(LandlordDeck.luck, 'Library fine: pay \$15'),
  luckToNorthStation(LandlordDeck.luck, 'Catch the train: advance to North Station'),
  luckToVista(LandlordDeck.luck, 'Advance to Vista Heights'),
  luckPayOther50(LandlordDeck.luck, 'You lost a bet: pay the other player \$50'),
  luckCollect150(LandlordDeck.luck, 'Your crossword win pays out: collect \$150'),
  // Family Fund.
  fundToStart(LandlordDeck.fund, 'Advance to Start'),
  fundCollect200(LandlordDeck.fund, 'Grandma sent a cheque: collect \$200'),
  fundPay50(LandlordDeck.fund, 'The car needed new tyres: pay \$50'),
  fundCollect50(LandlordDeck.fund, 'Garage sale profits: collect \$50'),
  fundJailFree(LandlordDeck.fund, 'Get out of jail free. Keep this card until needed'),
  fundToJail(LandlordDeck.fund, "Off to jail! You don't collect \$200"),
  fundCollect100a(LandlordDeck.fund, 'Your bonus came through: collect \$100'),
  fundCollect20(LandlordDeck.fund, 'You found \$20 in an old coat'),
  fundFromOther(LandlordDeck.fund, 'You helped them move house: collect \$10 from the other player'),
  fundCollect100b(LandlordDeck.fund, 'Your bake sale was a hit: collect \$100'),
  fundPay100(LandlordDeck.fund, 'The roof sprang a leak: pay \$100'),
  fundPay50b(LandlordDeck.fund, 'Music lessons: pay \$50'),
  fundCollect25(LandlordDeck.fund, 'Babysitting money: collect \$25'),
  fundRepairs(LandlordDeck.fund, 'Spring cleaning: pay \$40 per house and \$115 per hotel'),
  fundCollect10(LandlordDeck.fund, 'You won the quiz night: collect \$10'),
  fundCollect100c(LandlordDeck.fund, 'A forgotten savings account turns up: collect \$100');

  const LandlordCard(this.deck, this.text);

  final LandlordDeck deck;
  final String text;

  bool get jailFree => this == luckJailFree || this == fundJailFree;
}
