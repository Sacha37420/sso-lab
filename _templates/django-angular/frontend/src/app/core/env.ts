interface EnvWindow {
  __env?: { apiUrl?: string };
}

/** Base de l'API de cette app (même défaut que `ApiService`). */
export function apiUrl(): string {
  return (window as unknown as EnvWindow).__env?.apiUrl ?? 'http://localhost:__BACKEND_PORT__';
}

/**
 * Adresses auxquelles l'intercepteur joint le jeton de l'utilisateur — et à
 * elles seules (`carriesToken`, `token-scope.ts`). Une API du lab de plus
 * (storage…) appelée depuis le navigateur s'ajoute ici, sinon elle part sans
 * jeton (401) : c'est voulu, jamais l'origine entière.
 */
export function tokenBases(): string[] {
  return [apiUrl()];
}
