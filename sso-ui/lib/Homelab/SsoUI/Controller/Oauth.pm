package Homelab::SsoUI::Controller::Oauth;

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::URL;
use Mojo::Util qw(secure_compare);

# One-time authorization codes, keyed by code: { jwt, refresh_token,
# client_id, redirect_uri, expires_at }. In-process only — the config's
# `server.workers` must stay at 1 unless this is replaced with a shared
# store, since a code minted by one worker wouldn't be visible to another.
my %codes;

use constant CODE_TTL => 60;

sub _find_client ($c, $client_id) {
    return undef unless defined $client_id;
    for my $client (@{ $c->oauth_clients }) {
        return $client if $client->{client_id} eq $client_id;
    }
    return undef;
}

sub _random_code {
    my @chars = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');
    my $code = '';
    $code .= $chars[int(rand(@chars))] for 1 .. 48;
    return $code;
}

sub _purge_expired {
    my $now = time;
    delete $codes{$_} for grep { $codes{$_}{expires_at} < $now } keys %codes;
}

# GET /oauth/authorize?response_type=code&client_id=...&redirect_uri=...&state=...
sub authorize ($c) {
    my $client_id    = $c->param('client_id');
    my $redirect_uri = $c->param('redirect_uri');
    my $state        = $c->param('state') // '';

    my $client = _find_client($c, $client_id);
    unless ($client && $redirect_uri && $client->{redirect_uri} eq $redirect_uri) {
        return $c->render(
            template => 'oauth/error',
            layout   => 'login',
            status   => 400,
            message  => 'Unknown client or redirect_uri.',
        );
    }

    $c->render(
        template     => 'oauth/login',
        layout       => 'login',
        error        => undef,
        client_id    => $client_id,
        redirect_uri => $redirect_uri,
        state        => $state,
    );
}

# POST /oauth/authorize — credential submission
sub authorize_submit ($c) {
    my $client_id    = $c->param('client_id');
    my $redirect_uri = $c->param('redirect_uri');
    my $state        = $c->param('state') // '';
    my $email        = $c->param('email')    // '';
    my $password     = $c->param('password') // '';

    my $client = _find_client($c, $client_id);
    unless ($client && $redirect_uri && $client->{redirect_uri} eq $redirect_uri) {
        return $c->render(
            template => 'oauth/error',
            layout   => 'login',
            status   => 400,
            message  => 'Unknown client or redirect_uri.',
        );
    }

    my $render_form_error = sub ($msg) {
        $c->render(
            template     => 'oauth/login',
            layout       => 'login',
            error        => $msg,
            client_id    => $client_id,
            redirect_uri => $redirect_uri,
            state        => $state,
        );
    };

    return $render_form_error->('Email and password are required.')
        unless $email && $password;

    my $result = $c->api->login($email, $password);
    unless ($result->{success}) {
        my $msg = ($result->{_status} // 0) == 429
            ? 'Too many login attempts. Please wait 15 minutes.'
            : ($result->{error} // 'Login failed. Check your email and password.');
        return $render_form_error->($msg);
    }

    _purge_expired();
    my $code = _random_code();
    $codes{$code} = {
        jwt           => $result->{token},
        refresh_token => $result->{refresh_token},
        expires_in    => $result->{expires_in},
        client_id     => $client_id,
        redirect_uri  => $redirect_uri,
        expires_at    => time + CODE_TTL,
    };

    my $target = Mojo::URL->new($redirect_uri);
    $target->query->append(code => $code, state => $state);
    $c->redirect_to($target);
}

# POST /oauth/token — server-to-server code exchange
sub token ($c) {
    my $grant_type    = $c->param('grant_type')    // '';
    my $code          = $c->param('code')          // '';
    my $client_id     = $c->param('client_id')     // '';
    my $client_secret = $c->param('client_secret') // '';
    my $redirect_uri  = $c->param('redirect_uri')  // '';

    return $c->render(json => { error => 'unsupported_grant_type' }, status => 400)
        unless $grant_type eq 'authorization_code';

    my $client = _find_client($c, $client_id);
    return $c->render(json => { error => 'invalid_client' }, status => 401)
        unless $client && secure_compare($client->{client_secret}, $client_secret);

    _purge_expired();
    my $entry = delete $codes{$code};   # one-time use
    unless ($entry
        && $entry->{client_id} eq $client_id
        && $entry->{redirect_uri} eq $redirect_uri
        && $entry->{expires_at} >= time)
    {
        return $c->render(json => { error => 'invalid_grant' }, status => 400);
    }

    return $c->render(json => {
        access_token  => $entry->{jwt},
        refresh_token => $entry->{refresh_token},
        token_type    => 'Bearer',
        expires_in    => $entry->{expires_in},
    });
}

# GET /oauth/userinfo — Bearer-auth passthrough to homelab-api's introspect endpoint
sub userinfo ($c) {
    my $auth_header = $c->req->headers->authorization // '';
    my ($jwt) = $auth_header =~ /^Bearer\s+(.+)$/;

    return $c->render(json => { error => 'Token required' }, status => 401)
        unless $jwt;

    my $result = $c->api->introspect($jwt);
    my $status = delete $result->{_status} // 401;
    return $c->render(json => $result, status => $status);
}

1;
