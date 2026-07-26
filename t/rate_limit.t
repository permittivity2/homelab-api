#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

unless ($ENV{HOMELAB_API_CONFIG}) {
    plan skip_all => 'HOMELAB_API_CONFIG not set; skipping integration tests';
}

require Test::Mojo;

my $t = Test::Mojo->new('Homelab::API');

subtest 'rate limiting: 5 failed attempts then 429' => sub {
    my $test_email = 'ratelimit-test-' . time() . '@example.com';

    for my $i (1 .. 5) {
        $t->post_ok('/api/v1/auth/login',
            json => { email => $test_email, password => 'badpass' })
            ->status_is(401,
                "Attempt $i should return 401")
            ->json_is('/error', 'Invalid credentials',
                "Attempt $i error message correct")
            or die "Attempt $i failed";
    }

    $t->post_ok('/api/v1/auth/login',
        json => { email => $test_email, password => 'badpass' })
        ->status_is(429,
            'Attempt 6 should return 429')
        ->json_is('/error', 'Too many login attempts. Please try again in 15 minutes.',
            'Rate limit message correct');

    # Further attempts should also be blocked
    $t->post_ok('/api/v1/auth/login',
        json => { email => $test_email, password => 'badpass' })
        ->status_is(429,
            'Attempt 7 should return 429');
};

subtest 'rate limiting: different emails are independent' => sub {
    my $email1 = 'email1-' . time() . '@example.com';
    my $email2 = 'email2-' . time() . '@example.com';

    for my $i (1 .. 5) {
        $t->post_ok('/api/v1/auth/login',
            json => { email => $email1, password => 'badpass' })
            ->status_is(401, "Email1 attempt $i → 401");
    }

    # Email2 should not be blocked despite email1 being rate limited
    $t->post_ok('/api/v1/auth/login',
        json => { email => $email2, password => 'badpass' })
        ->status_is(401, 'Email2 first attempt → 401 (not rate limited)');
};

done_testing;
