// The same vector as app/test/crypto/reset_test.dart: the Dart client's signatures verify here.
import { describe, expect, it } from "vitest";
import { b64urlEncode } from "../src/lib/encoding";
import { claimMessage, resetMessage, verifyEd25519 } from "../src/lib/reset";

const fill = (n: number, v: number) => b64urlEncode(new Uint8Array(n).fill(v));

const vector = {
  signerPub: "0EqyMnQrtKs6E2i9RhXk5tAiSrcaAWuvhSCjMsl3hzc",
  sig: "2bTQ9TLFCiIhyFcaaiIdJG5EYZ5DWv4NnPBSezyszPNyhHTC--a4j2MKAtke7MRr2utg04wxqEkBylI2sYr7Dg",
  claimPub: "oJql9HpnWYAv-VX43C0qFKXJnSO-l_hkEn_5ODRVpPA",
  claimSig: "LhTcuzfu93E6nxxyr74-YtGzOYlxWkNdgLJQ91B6g4ur3w4Pew_ReiM27mRLUUZL3n6wWxp54OqR2kSob9TSAQ",
};

const statement = {
  resetId: "01JRESET000000000000000000",
  userId: "01JMOM0000000000000000000A",
  signerUserId: "01JADMIN000000000000000000",
  signerKind: "admin" as const,
  oldIdentityPub: fill(32, 1),
  claimPub: fill(32, 2),
  createdAt: 1763280000123,
};

describe("reset byte strings match the Dart client", () => {
  it("statement signature from Dart verifies", async () => {
    expect(await verifyEd25519(vector.signerPub, vector.sig, resetMessage(statement))).toBe(true);
    expect(await verifyEd25519(vector.signerPub, vector.sig, resetMessage({ ...statement, createdAt: statement.createdAt + 1 }))).toBe(false);
  });

  it("claim signature from Dart verifies", async () => {
    expect(await verifyEd25519(vector.claimPub, vector.claimSig, claimMessage(statement.resetId, fill(32, 3)))).toBe(true);
  });
});
