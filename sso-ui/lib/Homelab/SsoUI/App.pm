package Homelab::SsoUI::App;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::File qw(path);
use YAML::XS qw(LoadFile);
use Carp qw(croak);

use Homelab::SsoUI::Helper::API;

sub startup ($self) {
    my $config_file = $ENV{HOMELAB_SSO_UI_CONFIG} // '/etc/homelab/sso-ui/config.yml';
    my $cfg = LoadFile($config_file);
    $self->config($cfg);

    # Template and static asset paths — override with HOMELAB_SSO_UI_HOME for development
    my $home = path($ENV{HOMELAB_SSO_UI_HOME} // '/usr/share/homelab-sso-ui');
    push @{$self->renderer->paths}, $home->child('templates')->to_string;
    push @{$self->static->paths},   $home->child('public')->to_string;

    # IdP session — signed cookie holding the current user's JWT/refresh
    # token, so repeat /oauth/authorize requests (for any client) can skip
    # the login form entirely once the user has authenticated once. secrets
    # MUST be identical across all sso-ui instances, same convention as
    # drive-web-ui.
    croak 'secrets array required in sso-ui config.yml (must match all sso-ui instances)'
        unless $cfg->{secrets} && ref $cfg->{secrets} eq 'ARRAY';
    $self->secrets($cfg->{secrets});
    $self->sessions->cookie_name('homelab-sso');
    $self->sessions->secure($cfg->{session}{secure} // 1);
    $self->sessions->default_expiration($cfg->{session}{expiry} // 30 * 24 * 60 * 60);

    # Hypnotoad. Default listen port (2502) deliberately differs from
    # homelab-api (3000) and homelab-drive-web-ui (2501) — see
    # config/sso-ui.example.yml for why.
    my $srv = $cfg->{server} // {};
    $self->config(hypnotoad => {
        listen   => [$srv->{listen}  // 'http://127.0.0.1:2502'],
        pid_file => $srv->{pid_file} // '/var/lib/homelab/sso-ui-hypnotoad.pid',
        workers  => $srv->{workers}  // 1,
    });

    # Helpers
    $self->helper(api => sub ($c) {
        Homelab::SsoUI::Helper::API->new(
            base_url => $c->app->config->{homelab_api}{base_url} // 'https://api.example.com',
        );
    });
    $self->helper(oauth_clients => sub ($c) {
        $c->app->config->{clients} // [];
    });

    # Routes
    my $r = $self->routes;
    $r->namespaces(['Homelab::SsoUI::Controller']);

    $r->get('/health' => sub ($c) { $c->render(text => 'ok', status => 200) });

    $r->get('/oauth/authorize')->to('oauth#authorize');
    $r->post('/oauth/authorize')->to('oauth#authorize_submit');
    $r->post('/oauth/token')->to('oauth#token');
    $r->get('/oauth/userinfo')->to('oauth#userinfo');
    $r->get('/logout')->to('oauth#logout');
}

1;
