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

# Unauthenticated access redirects to the SSO login, not a local form
$t->get_ok('/drive')->status_is(302)->header_like(Location => qr{/oauth/authorize});

# Hitting /login with no session starts the same SSO redirect
$t->get_ok('/login')->status_is(302)->header_like(Location => qr{/oauth/authorize});

# A forged/stale OAuth callback (no matching session state) safely restarts
# the dance instead of accepting the code
$t->get_ok('/login?code=bogus&state=bogus')
  ->status_is(302)
  ->header_like(Location => qr{/oauth/authorize});

done_testing;
