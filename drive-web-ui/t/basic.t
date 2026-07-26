use strict;
use warnings;
use Test::More;
use Test::Mojo;

unless ($ENV{HOMELAB_DRIVE_WEB_UI_CONFIG}) {
    plan skip_all => 'Set HOMELAB_DRIVE_WEB_UI_CONFIG to run integration tests';
}

use lib 'lib';
use Mojolicious::Commands;

my $t = Test::Mojo->new('Homelab::DriveWebUI::App');

# Health check — no auth required
$t->get_ok('/health')->status_is(200)->content_is('ok');

# Login page — redirects if not logged in
$t->get_ok('/drive')->status_is(302)->header_like(Location => qr{/login});

# Login form renders
$t->get_ok('/login')->status_is(200)->text_like('title', qr/Sign In/);

# Login with bad credentials
$t->post_ok('/login', form => { email => 'bad@example.com', password => 'wrong' })
  ->status_is(200)
  ->text_like('.alert-error', qr/Login failed|Invalid|credentials/i);

done_testing;
