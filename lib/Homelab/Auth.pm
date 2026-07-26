package Homelab::Auth;

use strict;
use warnings;
use Mojo::Promise;
use Homelab::Utils::Password qw(verify_dovecot_password);
use Homelab::Utils::JWT qw(generate_token verify_token generate_refresh_token);
use Carp qw(croak);

sub new {
    my ($class, $db, $config) = @_;
    my $self = {
        db     => $db,
        config => $config,
    };
    bless $self, $class;
    return $self;
}

sub login {
    my ($self, $email, $password) = @_;

    return { error => 'Email and password required' }
        unless $email && $password;

    my ($username, $domain) = split /@/, $email;
    return { error => 'Invalid email format' }
        unless $username && $domain;

    my $user = $self->{db}->query_row(
        'SELECT id, username, domain, password, active, quota_mb FROM dovecot.users WHERE username = ? AND domain = ? AND active = ?',
        $username, $domain, 'Y'
    );

    return { error => 'Invalid credentials' }
        unless $user;

    my $verified = verify_dovecot_password($password, $user->{password});
    return { error => 'Invalid credentials' }
        unless $verified;

    my ($jwt, $expires_in) = generate_token($self->{config}, $email);
    my $refresh_token = generate_refresh_token();

    my $refresh_exp = 30 * 24 * 60 * 60;
    $self->{db}->query(
        'INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + ? * INTERVAL \'1 second\')',
        $user->{id}, $refresh_token, $refresh_exp
    );

    return {
        success => 1,
        token => $jwt,
        expires_in => $expires_in,
        user => {
            email => $email,
            quota_mb => $user->{quota_mb},
        },
        refresh_token => $refresh_token,
    };
}

sub validate {
    my ($self, $token) = @_;

    return { error => 'Token required' }
        unless $token;

    my $payload = verify_token($self->{config}, $token);
    return { error => 'Invalid or expired token' }
        unless $payload;

    return {
        valid => 1,
        user => {
            email => $payload->{email},
        },
    };
}

sub refresh {
    my ($self, $refresh_token) = @_;

    return { error => 'Refresh token required' }
        unless $refresh_token;

    my $token_record = $self->{db}->query_row(
        'SELECT user_id FROM api.refresh_tokens WHERE token = ? AND revoked = FALSE AND expires_at > NOW()',
        $refresh_token
    );

    return { error => 'Invalid or expired refresh token' }
        unless $token_record;

    my $user = $self->{db}->query_row(
        'SELECT id, username, domain FROM dovecot.users WHERE id = ?',
        $token_record->{user_id}
    );

    return { error => 'User not found' }
        unless $user;

    my $email = $user->{username} . '@' . $user->{domain};
    my ($jwt, $expires_in) = generate_token($self->{config}, $email);

    my $new_refresh_token = generate_refresh_token();
    my $refresh_exp = 30 * 24 * 60 * 60;

    $self->{db}->query(
        'INSERT INTO api.refresh_tokens (user_id, token, expires_at) VALUES (?, ?, NOW() + ? * INTERVAL \'1 second\')',
        $user->{id}, $new_refresh_token, $refresh_exp
    );

    return {
        success => 1,
        token => $jwt,
        expires_in => $expires_in,
        refresh_token => $new_refresh_token,
    };
}

sub logout {
    my ($self, $refresh_token) = @_;

    return { error => 'Refresh token required' }
        unless $refresh_token;

    $self->{db}->query(
        'UPDATE api.refresh_tokens SET revoked = TRUE WHERE token = ?',
        $refresh_token
    );

    return { success => 1 };
}

1;
