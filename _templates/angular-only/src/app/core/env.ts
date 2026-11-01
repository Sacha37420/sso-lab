interface EnvWindow {
  __env?: { apiUrl?: string };
}

/**
 * Adresses auxquelles l'intercepteur joint le jeton de l'utilisateur — et à
 * elles seules (`carriesToken`, `token-scope.ts`). Vide par défaut : une app
 * Angular seule n'appelle aucune API. Toute API du lab appelée depuis le
 * navigateur (storage…) s'ajoute ici, jamais l'origine entière.
 */
export function tokenBases(): string[] {
  const api = (window as unknown as EnvWindow).__env?.apiUrl;
  return api ? [api] : [];
}
