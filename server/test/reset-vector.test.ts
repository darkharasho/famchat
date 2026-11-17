// The same vector as app/test/crypto/reset_test.dart: the Dart client's signatures verify here.
import { describe, expect, it } from "vitest";
import { b64urlEncode } from "../src/lib/encoding";
import { claimMessage, promotionMessage, promotionMessageV2, resetMessage, verifyEd25519 } from "../src/lib/reset";

const fill = (n: number, v: number) => b64urlEncode(new Uint8Array(n).fill(v));

const vector = {
  signerPub: "0EqyMnQrtKs6E2i9RhXk5tAiSrcaAWuvhSCjMsl3hzc",
  sig: "2bTQ9TLFCiIhyFcaaiIdJG5EYZ5DWv4NnPBSezyszPNyhHTC--a4j2MKAtke7MRr2utg04wxqEkBylI2sYr7Dg",
  claimPub: "oJql9HpnWYAv-VX43C0qFKXJnSO-l_hkEn_5ODRVpPA",
  claimSig: "Jlze_kYQ0E_SOE2Vk6N1uO6MZap0wohPBjrFZiznTKtHmwZP47d9H15vqMVFkDpQEjwNFcQFnryJ9rQxdVGwDg",
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

// v2 admin proof: "famchat-admin-v2" || str("1") || str(userId) || str(byUserId), Ed25519 over those bytes
// (str = u16 big-endian length + UTF-8). Generated once with node:crypto: the PKCS8 key built from `seed`
// signed the message; signerPub is that key's public half. Do not regenerate: the Dart test copies it.
const v2Vector = {
  seed: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
  signerPub: "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg",
  familyId: 1,
  userId: "01JMOM0000000000000000000A",
  byUserId: "01JADMIN000000000000000000",
  sig: "R15HUaNwSBgJ2AhhhRTOuzSYuCYKEiSPof7eXnK4EOEZPSgMz8u-wzyzgveO6l6cWd6NifFbfeKcnY23AQs-Dw",
};

describe("reset byte strings match the Dart client", () => {
  it("statement signature from Dart verifies", async () => {
    expect(await verifyEd25519(vector.signerPub, vector.sig, resetMessage(statement))).toBe(true);
    expect(await verifyEd25519(vector.signerPub, vector.sig, resetMessage({ ...statement, createdAt: statement.createdAt + 1 }))).toBe(false);
  });

  it("promotion signature from Dart verifies", async () => {
    const promotionSig = "KunKvoovZnGzngrDT31ZUMxdUZOSNCnlGs7dvdjBtm_HP8sxqHvWWayKVARJih5XqgHGEuTVT37R-NHKXysADQ";
    expect(await verifyEd25519(vector.signerPub, promotionSig, promotionMessage(statement.userId, statement.signerUserId))).toBe(true);
    expect(await verifyEd25519(vector.signerPub, promotionSig, promotionMessage(statement.signerUserId, statement.userId))).toBe(false);
  });

  it("claim signature from Dart verifies", async () => {
    expect(await verifyEd25519(vector.claimPub, vector.claimSig, claimMessage(vector.claimPub, fill(32, 3)))).toBe(true);
  });

  it("v2 promotion signature (shared constant, copied verbatim into the Dart test) verifies", async () => {
    expect(await verifyEd25519(v2Vector.signerPub, v2Vector.sig, promotionMessageV2(v2Vector.familyId, v2Vector.userId, v2Vector.byUserId))).toBe(true);
    expect(await verifyEd25519(v2Vector.signerPub, v2Vector.sig, promotionMessageV2(2, v2Vector.userId, v2Vector.byUserId))).toBe(false);
    expect(await verifyEd25519(v2Vector.signerPub, v2Vector.sig, promotionMessage(v2Vector.userId, v2Vector.byUserId))).toBe(false);
  });
});
