package Homelab::Roles;

use strict;
use warnings;

sub new {
    my ($class, $db, $config) = @_;
    my $self = {
        db     => $db,
        config => $config,
    };
    bless $self, $class;
    return $self;
}

sub user_id {
    my ($self, $email) = @_;
    return undef unless $email;
    my ($username, $domain) = split /@/, $email;
    return undef unless $username && $domain;
    my $user = $self->{db}->query_row(
        'SELECT id FROM dovecot.users WHERE username = ? AND domain = ? AND active = ?',
        $username, $domain, 'Y'
    );
    return $user ? $user->{id} : undef;
}

sub email_for_refresh_token {
    my ($self, $refresh_token) = @_;
    return undef unless $refresh_token;

    my $token_record = $self->{db}->query_row(
        'SELECT user_id FROM api.refresh_tokens WHERE token = ? AND revoked = FALSE AND expires_at > NOW()',
        $refresh_token
    );
    return undef unless $token_record;

    my $user = $self->{db}->query_row(
        'SELECT username, domain FROM dovecot.users WHERE id = ?',
        $token_record->{user_id}
    );
    return undef unless $user;

    return $user->{username} . '@' . $user->{domain};
}

sub user_roles {
    my ($self, $email) = @_;
    my $user_id = $self->user_id($email);
    return [] unless $user_id;
    my $rows = $self->{db}->query_rows(
        'SELECT r.name FROM api.user_roles ur
         JOIN api.roles r ON r.id = ur.role_id
         WHERE ur.user_id = ?',
        $user_id
    );
    return [ map { $_->{name} } @$rows ];
}

sub is_site_admin {
    my ($self, $email) = @_;
    my $roles = $self->user_roles($email);
    return (grep { $_ eq 'site_admin' } @$roles) ? 1 : 0;
}

sub user_has_permission {
    my ($self, $email, $method, $path_pattern) = @_;
    my $user_id = $self->user_id($email);
    return 0 unless $user_id;

    my $endpoint_key = uc($method) . ' ' . $path_pattern;
    my $row = $self->{db}->query_row(
        'SELECT 1 FROM api.user_roles ur
         JOIN api.role_permissions rp ON rp.role_id = ur.role_id
         WHERE ur.user_id = ? AND rp.endpoint_key = ?
         LIMIT 1',
        $user_id, $endpoint_key
    );
    return $row ? 1 : 0;
}

sub list_roles {
    my ($self) = @_;
    return $self->{db}->query_rows('SELECT id, name, description FROM api.roles ORDER BY name');
}

sub _role_id {
    my ($self, $role_name) = @_;
    my $role = $self->{db}->query_row('SELECT id FROM api.roles WHERE name = ?', $role_name);
    return $role ? $role->{id} : undef;
}

sub assign_role {
    my ($self, $email, $role_name, $granted_by_email) = @_;

    my $user_id = $self->user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $role_id = $self->_role_id($role_name);
    return { error => 'Unknown role' } unless $role_id;

    my $granted_by = $granted_by_email ? $self->user_id($granted_by_email) : undef;

    $self->{db}->query(
        'INSERT INTO api.user_roles (user_id, role_id, granted_by) VALUES (?, ?, ?)
         ON CONFLICT (user_id, role_id) DO NOTHING',
        $user_id, $role_id, $granted_by
    );

    return { success => 1, email => $email, roles => $self->user_roles($email) };
}

sub revoke_role {
    my ($self, $email, $role_name) = @_;

    my $user_id = $self->user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $role_id = $self->_role_id($role_name);
    return { error => 'Unknown role' } unless $role_id;

    if ($role_name eq 'site_admin') {
        my $count = $self->{db}->query_row(
            'SELECT COUNT(*) AS n FROM api.user_roles WHERE role_id = ?',
            $role_id
        );
        my $is_holder = $self->{db}->query_row(
            'SELECT 1 FROM api.user_roles WHERE user_id = ? AND role_id = ?',
            $user_id, $role_id
        );
        if ($is_holder && $count && $count->{n} <= 1) {
            return { error => 'Cannot revoke site_admin from the last remaining admin' };
        }
    }

    $self->{db}->query(
        'DELETE FROM api.user_roles WHERE user_id = ? AND role_id = ?',
        $user_id, $role_id
    );

    return { success => 1, email => $email, roles => $self->user_roles($email) };
}

sub grant_endpoint {
    my ($self, $role_name, $endpoint_key, $granted_by_email) = @_;

    my $role_id = $self->_role_id($role_name);
    return { error => 'Unknown role' } unless $role_id;

    my $granted_by = $granted_by_email ? $self->user_id($granted_by_email) : undef;

    $self->{db}->query(
        'INSERT INTO api.role_permissions (role_id, endpoint_key, granted_by) VALUES (?, ?, ?)
         ON CONFLICT (role_id, endpoint_key) DO NOTHING',
        $role_id, $endpoint_key, $granted_by
    );

    return { success => 1, role => $role_name, endpoint => $endpoint_key };
}

sub revoke_endpoint {
    my ($self, $role_name, $endpoint_key) = @_;

    my $role_id = $self->_role_id($role_name);
    return { error => 'Unknown role' } unless $role_id;

    $self->{db}->query(
        'DELETE FROM api.role_permissions WHERE role_id = ? AND endpoint_key = ?',
        $role_id, $endpoint_key
    );

    return { success => 1, role => $role_name, endpoint => $endpoint_key };
}

sub list_role_permissions {
    my ($self, $role_name) = @_;

    my $role_id = $self->_role_id($role_name);
    return { error => 'Unknown role' } unless $role_id;

    my $rows = $self->{db}->query_rows(
        'SELECT endpoint_key FROM api.role_permissions WHERE role_id = ? ORDER BY endpoint_key',
        $role_id
    );
    return { success => 1, role => $role_name, permissions => [ map { $_->{endpoint_key} } @$rows ] };
}

sub revoke_all_tokens {
    my ($self, $email) = @_;

    my $user_id = $self->user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $result = $self->{db}->query(
        'UPDATE api.refresh_tokens SET revoked = TRUE WHERE user_id = ? AND revoked = FALSE',
        $user_id
    );

    return { success => 1, email => $email, revoked_count => $result->rows };
}

1;
