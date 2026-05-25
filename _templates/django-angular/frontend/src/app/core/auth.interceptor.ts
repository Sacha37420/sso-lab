import { HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { from, switchMap } from 'rxjs';
import { KeycloakService } from './keycloak.service';

/**
 * Intercepteur HTTP qui renouvelle le token Keycloak si nécessaire,
 * puis injecte le Bearer dans l'en-tête Authorization de chaque requête.
 */
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const kc = inject(KeycloakService);

  return from(kc.updateToken(30)).pipe(
    switchMap(() => {
      const token = kc.getToken();
      if (token) {
        req = req.clone({
          setHeaders: { Authorization: `Bearer ${token}` },
        });
      }
      return next(req);
    }),
  );
};
