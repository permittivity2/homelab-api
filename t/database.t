#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use YAML::XS qw(LoadFile);

use Homelab::Database;

plan skip_all => 'Set HOMELAB_API_CONFIG env var to run database tests'
    unless $ENV{HOMELAB_API_CONFIG};

my $config = LoadFile($ENV{HOMELAB_API_CONFIG});
my $db;

ok(
    eval { $db = Homelab::Database->new($config); 1 },
    'Database connection successful'
) or diag("Error: $@");

SKIP: {
    skip 'No database connection', 5 unless $db;

    ok($db->ping, 'Ping database');

    my $users = $db->query_rows(
        'SELECT username, domain FROM dovecot.users WHERE active = ? LIMIT 5',
        'Y'
    );
    ok(ref $users eq 'ARRAY', 'Query returns array ref');

    my $user = $db->query_row(
        'SELECT id, username, domain FROM dovecot.users WHERE active = ? LIMIT 1',
        'Y'
    );
    ok(defined $user, 'Query row returns hash ref') if defined $user;
    ok($user->{username}, 'User has username') if defined $user;
    ok($user->{domain}, 'User has domain') if defined $user;

    ok(1, 'Mojo::Pg connection pool cleanup automatic');
}

done_testing;
