package Homelab::Roles;

use strict;
use warnings;
use Homelab::Utils::Passphrase qw(generate_passphrase);
use Homelab::Utils::Password    qw(hash_password);

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

# Single-JOIN version of list_roles, embedding each role's permissions —
# avoids the N+1 pattern of list_roles + one list_role_permissions call per
# role. Note: site_admin's permissions here reflect only what's explicitly
# seeded in api.role_permissions (e.g. /api/v1/backup/*) — its /api/v1/admin/*
# access is hardcoded (is_site_admin), not driven by this table, so it will
# never show up here even though site_admin can call it.
sub list_roles_with_permissions {
    my ($self) = @_;
    my $rows = $self->{db}->query_rows(
        'SELECT r.id, r.name, r.description, rp.endpoint_key
         FROM api.roles r
         LEFT JOIN api.role_permissions rp ON rp.role_id = r.id
         ORDER BY r.name, rp.endpoint_key'
    );
    my (%by_id, @order);
    for my $row (@$rows) {
        unless ($by_id{$row->{id}}) {
            $by_id{$row->{id}} = { id => $row->{id}, name => $row->{name},
                                    description => $row->{description}, permissions => [] };
            push @order, $by_id{$row->{id}};
        }
        push @{ $by_id{$row->{id}}{permissions} }, $row->{endpoint_key} if defined $row->{endpoint_key};
    }
    return \@order;
}

sub _role_id {
    my ($self, $role_name) = @_;
    my $role = $self->{db}->query_row('SELECT id FROM api.roles WHERE name = ?', $role_name);
    return $role ? $role->{id} : undef;
}

# Hardcoded bypass mirrors is_site_admin's own rationale: a bad
# role_grant_permissions row can never lock site_admin out of creating or
# re-granting its own recovery path.
sub can_grant_role {
    my ($self, $granter_email, $grantee_role_name) = @_;
    return 1 if $self->is_site_admin($granter_email);
    my $row = $self->{db}->query_row(
        'SELECT 1 FROM api.role_grant_permissions rgp
         JOIN api.user_roles ur ON ur.role_id = rgp.granter_role_id
         JOIN api.roles ge ON ge.id = rgp.grantee_role_id
         WHERE ur.user_id = ? AND ge.name = ? LIMIT 1',
        $self->user_id($granter_email), $grantee_role_name
    );
    return $row ? 1 : 0;
}

# Creates a dovecot.users account (idempotent — an existing account just has
# the role assigned) and its initial role. Never accepts a client-supplied
# password: the plaintext is generated server-side and returned exactly
# once, same posture as the existing reset-password endpoint.
sub create_user {
    my ($self, $email, $role_name, $creator_email, %opts) = @_;

    return { error => 'Unknown role' } unless $self->_role_id($role_name);
    return { error => 'Not authorized to grant this role' }
        unless $self->can_grant_role($creator_email, $role_name);

    my ($username, $domain) = split /@/, $email;
    return { error => 'Invalid email format' } unless $username && $domain;

    my $existing = $self->{db}->query_row(
        'SELECT id FROM dovecot.users WHERE username = ? AND domain = ?', $username, $domain
    );
    if ($existing) {
        # Idempotent: never regenerate/return a password for an account
        # that already exists -- assign_role() is itself idempotent (ON
        # CONFLICT DO NOTHING), so re-running create-user against an
        # existing account just ensures the role, harmlessly.
        $self->assign_role($email, $role_name, $creator_email);
        return { success => 1, created => 0, user => { email => $email },
                 roles => $self->user_roles($email) };
    }

    my $plaintext = generate_passphrase(wordlist_path => $self->{config}{passphrase}{wordlist_path});
    my $hash = hash_password($plaintext);
    my $quota_mb = $opts{quota_mb} // 1024;

    # home/uid/gid are NOT NULL with no default on dovecot.users, but a
    # service account created here has no real mailbox -- use "nobody"
    # sentinel values (matches migration 012's INSERT grant column list).
    $self->{db}->query(
        "INSERT INTO dovecot.users (username, domain, password, home, uid, gid, active, quota_mb)
         VALUES (?, ?, ?, '/nonexistent', 65534, 65534, ?, ?)",
        $username, $domain, $hash, 'Y', $quota_mb
    );
    $self->assign_role($email, $role_name, $creator_email);

    return { success => 1, created => 1, user => { email => $email, quota_mb => $quota_mb },
             role => $role_name, password => $plaintext };
}

sub assign_role {
    my ($self, $email, $role_name, $granted_by_email) = @_;

    my $user_id = $self->user_id($email);
    return { error => 'User not found' } unless $user_id;

    my $role_id = $self->_role_id($role_name);
    return { error => 'Unknown role' } unless $role_id;

    if ($granted_by_email && !$self->can_grant_role($granted_by_email, $role_name)) {
        return { error => 'Not authorized to grant this role' };
    }

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
