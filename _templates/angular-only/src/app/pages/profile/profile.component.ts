import { Component, inject } from '@angular/core';
import { NavbarComponent }  from '../../shared/navbar/navbar.component';
import { KeycloakService }  from '../../core/keycloak.service';

@Component({
  selector: 'app-profile',
  standalone: true,
  imports: [NavbarComponent],
  templateUrl: './profile.component.html',
  styleUrl: './profile.component.scss',
})
export class ProfileComponent {
  private kc = inject(KeycloakService);

  get username(): string  { return this.kc.username; }
  get email(): string     { return this.kc.email; }
  get groups(): string[]  { return this.kc.groups; }
  get token(): string     { return this.kc.getToken() ?? ''; }
}
