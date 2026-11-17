import type { FamilyHub, PushJob } from "./hub";

export interface Env {
  DB: D1Database;
  HUB: DurableObjectNamespace<FamilyHub>;
  MEDIA: R2Bucket;
  TOKEN_SECRET: string;
  BOOTSTRAP_SECRET: string;
  APP_ORIGIN: string;
  /** Offline members' new messages, consumed by this Worker's queue() handler. */
  PUSH_QUEUE?: Queue<PushJob>;
  /** The Firebase service-account key (JSON). Without it push is off. */
  FCM_SERVICE_ACCOUNT?: string;
  /** KLIPY app key for GIF search (docs/protocol.md "GIFs"); unset hides GIFs in the app. */
  KLIPY_APP_KEY?: string;
  /** "<team id>.dev.famchat.app": iOS opens famchat.dev/join links in the app. */
  APPLE_APP_ID?: string;
  /** Comma-separated SHA-256 fingerprints of the Android signing certificates (Play and upload). */
  ANDROID_CERT_SHA256?: string;
}

export interface AppVars {
  userId: string;
  deviceId: string;
  isAdmin: boolean;
  /** The caller is a reviewer account (docs/protocol.md "Reviewer accounts"). */
  reviewer: boolean;
  /** The caller is the operator (users.operator). */
  operator: boolean;
}

export type AppEnv = { Bindings: Env; Variables: AppVars };
