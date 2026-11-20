import type { StaffRole } from "../lib/staff/permissions.ts";

/** The signed-in staff member (set by the session middleware). */
export interface StaffContext {
  id: string;
  handle: string;
  role: StaffRole;
}

/** The current console session. `csrfToken` is the synchronizer token every form and JSON write must carry. */
export interface SessionContext {
  id: string;
  csrfToken: string;
  csrfHash: Buffer;
  createdAt: Date;
  stepUpAt: Date | null;
}

export type AdminEnv = {
  Variables: {
    staff: StaffContext | undefined;
    session: SessionContext | undefined;
    /** The matched route answers JSON (passkey ceremonies): errors are JSON too. */
    json: boolean;
  };
};
