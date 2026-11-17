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
