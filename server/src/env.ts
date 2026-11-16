export interface Env {
  DB: D1Database;
  TOKEN_SECRET: string;
  BOOTSTRAP_SECRET: string;
  APP_ORIGIN: string;
}

export interface AppVars {
  userId: string;
  deviceId: string;
  isAdmin: boolean;
}

export type AppEnv = { Bindings: Env; Variables: AppVars };
