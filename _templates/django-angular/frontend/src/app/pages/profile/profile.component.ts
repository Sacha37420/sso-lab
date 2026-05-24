import { Component, inject, OnInit } from '@angular/core';
import { DatePipe } from '@angular/common';
import { NavbarComponent } from '../../shared/navbar/navbar.component';
import { ApiService }      from '../../core/api.service';

interface Department {
  id: number; name: string; description: string; member_count: number;
}

interface UserRecord {
  email: string; display_name: string;
  department: Pick<Department, 'id' | 'name'> | null;
  registered_at: string;
}

interface MeResponse {
  email: string; username: string; groups: string[];
  display_name: string; department: Department | null;
  registered_at: string; is_new: boolean;
}

@Component({
  selector: 'app-profile',
  standalone: true,
  imports: [DatePipe, NavbarComponent],
  templateUrl: './profile.component.html',
  styleUrl: './profile.component.scss',
})
export class ProfileComponent implements OnInit {
  private api = inject(ApiService);

  me:      MeResponse | null = null;
  users:   UserRecord[]      = [];
  loading = true;
  error:   string | null     = null;

  ngOnInit(): void {
    this.api.getMe().subscribe({
      next: (data) => {
        this.me      = data as MeResponse;
        this.loading = false;
        this.loadUsers();
      },
      error: (err) => {
        this.loading = false;
        this.error   = `Impossible de charger le profil (${err.status ?? 'réseau'})`;
      },
    });
  }

  private loadUsers(): void {
    this.api.getUsers().subscribe({
      next: (users) => { this.users = users as UserRecord[]; },
    });
  }
}
