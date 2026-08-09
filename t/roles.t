#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'HOMELAB_API_CONFIG not set; skipping integration tests';
}

require Test::Mojo;
require Homelab::Database;
require Homelab::Utils::Password;
use YAML::XS qw(LoadFile);

my $EMAIL    = 'permittivity@example.com';
my $PASSWORD = 'Mcl532vtc896?.';

my $config = LoadFile($ENV{HOMELAB_API_CONFIG});
my $db     = Homelab::Database->new($config);

# Test-only bootstrap/cleanup helpers — direct DB access, bypassing the API
# entirely, since the admin endpoints themselves require an existing admin
# to call them (there's no other way to create the very first one).
sub _set_site_admin {
    my ($want) = @_;
    my $user = $db->query_row(
        'SELECT id FROM dovecot.users WHERE username = ? AND domain = ? AND active = ?',
        split(/\@/, $EMAIL), 'Y'
    );
    my $role = $db->query_row("SELECT id FROM api.roles WHERE name = 'site_admin'");
    if ($want) {
        $db->query(
            'INSERT INTO api.user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING',
            $user->{id}, $role->{id}
        );
    } else {
        $db->query(
            'DELETE FROM api.user_roles WHERE user_id = ? AND role_id = ?',
            $user->{id}, $role->{id}
        );
    }
}

my $t = Test::Mojo->new('Homelab::API');

sub _login {
    my ($password) = @_;
    my $r = $t->post_ok('/api/v1/auth/login', json => { email => $EMAIL, password => $password })
        ->status_is(200)->tx->res->json;
    return $r->{token};
}

subtest 'non-admin gets 403 on admin routes' => sub {
    _set_site_admin(0);
    my $token = _login($PASSWORD);
    ok($token, 'got a token as a plain (non-admin) user');

    $t->get_ok('/api/v1/admin/roles', { Authorization => "Bearer $token" })->status_is(403);
    $t->post_ok('/api/v1/admin/users/' . $EMAIL . '/roles',
        { Authorization => "Bearer $token" }, json => { role => 'site_admin' })
        ->status_is(403);
    $t->post_ok('/api/v1/admin/users/' . $EMAIL . '/reset-password',
        { Authorization => "Bearer $token" })
        ->status_is(403);
    $t->post_ok('/api/v1/admin/users/' . $EMAIL . '/force-relogin',
        { Authorization => "Bearer $token" })
        ->status_is(403);
};

subtest 'as site_admin' => sub {
    _set_site_admin(1);
    my $token = _login($PASSWORD);
    ok($token, 'got a token as a site_admin');
    my $auth = { Authorization => "Bearer $token" };

    subtest 'list roles' => sub {
        $t->get_ok('/api/v1/admin/roles', $auth)->status_is(200)->json_is('/success', 1);
        my $names = [ map { $_->{name} } @{ $t->tx->res->json->{roles} } ];
        ok((grep { $_ eq 'user' } @$names), 'user role exists');
        ok((grep { $_ eq 'site_admin' } @$names), 'site_admin role exists');
    };

    subtest 'permission grant/revoke on an existing endpoint' => sub {
        my $endpoint = 'GET /api/v1/drive/quota';

        $t->get_ok('/api/v1/admin/roles/user/permissions', $auth)->status_is(200);
        my $perms = $t->tx->res->json->{permissions};
        ok((grep { $_ eq $endpoint } @$perms), 'quota endpoint is seeded for user role');

        $t->delete_ok('/api/v1/admin/roles/user/permissions' . '?endpoint=' . _url_escape($endpoint), $auth)
            ->status_is(200)->json_is('/success', 1);

        $t->get_ok('/api/v1/drive/quota', $auth)->status_is(403);

        $t->get_ok('/api/v1/admin/roles', $auth)->status_is(200)->json_is('/success', 1);

        $t->post_ok('/api/v1/admin/roles/user/permissions', $auth, json => { endpoint => $endpoint })
            ->status_is(201)->json_is('/success', 1);

        $t->get_ok('/api/v1/drive/quota', $auth)->status_is(200);
    };

    subtest 'unknown endpoint string rejected on grant' => sub {
        $t->post_ok('/api/v1/admin/roles/user/permissions', $auth,
            json => { endpoint => 'GET /api/v1/totally/not/a/real/route' })
            ->status_is(400);
    };

    subtest 'reset-password returns a working passphrase and ignores client input' => sub {
        $t->post_ok('/api/v1/admin/users/' . $EMAIL . '/reset-password', $auth,
            json => { new_password => 'whatever-i-want' })
            ->status_is(200)->json_is('/success', 1);

        my $new_password = $t->tx->res->json->{password};
        ok($new_password, 'got a generated passphrase back');
        like($new_password, qr/^[a-z]{3,8}-[a-z]{3,8}$/, 'passphrase shape matches spec');
        cmp_ok(length($new_password), '>=', 12, 'at least 12 chars total');
        cmp_ok(length($new_password), '<=', 20, 'at most 20 chars total');
        isnt($new_password, 'whatever-i-want', 'client-supplied password was ignored');

        my $new_token = _login($new_password);
        ok($new_token, 'the generated passphrase actually logs in');

        # Restore the original fixture password so other test files (which
        # hardcode it) keep working after this file runs.
        my $restored_hash = Homelab::Utils::Password::hash_password($PASSWORD);
        my $user = $db->query_row(
            'SELECT id FROM dovecot.users WHERE username = ? AND domain = ? AND active = ?',
            split(/\@/, $EMAIL), 'Y'
        );
        $db->query('UPDATE dovecot.users SET password = ? WHERE id = ?', $restored_hash, $user->{id});
        ok(_login($PASSWORD), 'original fixture password restored and still works');
    };

    subtest 'force-relogin / revoke-tokens invalidate existing refresh tokens' => sub {
        my $login = $t->post_ok('/api/v1/auth/login', json => { email => $EMAIL, password => $PASSWORD })
            ->status_is(200)->tx->res->json;
        my $refresh_token = $login->{refresh_token};
        ok($refresh_token, 'got a refresh token to invalidate');

        $t->post_ok('/api/v1/admin/users/' . $EMAIL . '/force-relogin', $auth)
            ->status_is(200)->json_is('/success', 1);

        # Verify at the DB level rather than round-tripping cookies through
        # Test::Mojo's UA — simpler and just as meaningful: confirm the
        # specific refresh token issued above is now revoked.
        my $row = $db->query_row(
            'SELECT revoked FROM api.refresh_tokens WHERE token = ?', $refresh_token
        );
        ok($row && $row->{revoked}, 'refresh token is revoked after force-relogin');
    };
};

subtest 'cannot revoke site_admin from the last remaining admin' => sub {
    my $token = _login($PASSWORD);
    my $auth  = { Authorization => "Bearer $token" };

    $t->delete_ok('/api/v1/admin/users/' . $EMAIL . '/roles/site_admin', $auth)
        ->status_is(400);

    $t->get_ok('/api/v1/admin/users/' . $EMAIL . '/roles', $auth)
        ->status_is(200);
    ok((grep { $_ eq 'site_admin' } @{ $t->tx->res->json->{roles} }), 'still admin after blocked revoke');
};

# Leave the fixture account without site_admin so future runs of this file
# (and any other test file relying on the plain-user default) start clean.
_set_site_admin(0);

sub _url_escape {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

done_testing;
