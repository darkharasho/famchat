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
}

export interface AppVars {
  userId: string;
  deviceId: string;
  isAdmin: boolean;
}

export type AppEnv = { Bindings: Env; Variables: AppVars };
