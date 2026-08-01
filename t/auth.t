#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::XS qw(decode_json);

plan skip_all => 'Set HOMELAB_API_CONFIG env var to run auth tests'
    unless $ENV{HOMELAB_API_CONFIG};

use Test::Mojo;
my $t = Test::Mojo->new('Homelab::API');

subtest 'Health endpoint' => sub {
    $t->get_ok('/api/v1/health')
        ->status_is(200)
        ->json_is('/success', undef)  # health endpoint returns status, not success
        ->json_is('/status', 'ok');
};

subtest 'Login endpoint' => sub {
    subtest 'Missing credentials' => sub {
        $t->post_ok('/api/v1/auth/login', json => {})
            ->status_is(400)
            ->json_is('/error', 'Email and password required');
    };

    subtest 'Invalid credentials' => sub {
        $t->post_ok('/api/v1/auth/login', json => {
            email => 'nonexistent@example.com',
            password => 'wrong'
        })->status_is(401)
            ->json_is('/error', 'Invalid credentials');
    };

    subtest 'Special characters in password' => sub {
        $t->post_ok('/api/v1/auth/login', json => {
            email => 'nonexistent@example.com',
            password => 'pass$with?special#chars!'
        })->status_is(401)
            ->json_is('/error', 'Invalid credentials');
    };
};

subtest 'Validate endpoint' => sub {
    subtest 'Missing token' => sub {
        $t->get_ok('/api/v1/auth/validate')
            ->status_is(401)
            ->json_is('/error', 'Token required');
    };

    subtest 'Invalid token' => sub {
        $t->get_ok('/api/v1/auth/validate', {
            'Authorization' => 'Bearer invalid.token.here'
        })->status_is(401)
            ->json_is('/error', 'Invalid or expired token');
    };
};

subtest 'Introspect endpoint' => sub {
    subtest 'Missing token' => sub {
        $t->get_ok('/api/v1/auth/introspect')
            ->status_is(401)
            ->json_is('/error', 'Token required');
    };

    subtest 'Invalid token' => sub {
        $t->get_ok('/api/v1/auth/introspect', {
            'Authorization' => 'Bearer invalid.token.here'
        })->status_is(401)
            ->json_is('/error', 'Invalid or expired token');
    };
};

subtest 'Logout endpoint' => sub {
    subtest 'Missing refresh token' => sub {
        $t->post_ok('/api/v1/auth/logout')
            ->status_is(401)
            ->json_is('/error', 'Refresh token required');
    };
};

subtest 'Refresh endpoint' => sub {
    subtest 'Missing refresh token' => sub {
        $t->post_ok('/api/v1/auth/refresh')
            ->status_is(401)
            ->json_is('/error', 'Refresh token required');
    };

    subtest 'Invalid refresh token' => sub {
        $t->post_ok('/api/v1/auth/refresh', {}, {
            'Cookie' => 'homelab-token=invalid'
        })->status_is(401)
            ->json_is('/error', 'Invalid or expired refresh token');
    };
};

done_testing;
