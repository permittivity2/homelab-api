package Homelab::SsoUI::Helper::API;

use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json);

has 'base_url' => 'https://api.example.com';
has '_ua' => sub {
    Mojo::UserAgent->new(connect_timeout => 10, request_timeout => 15);
};

# POST /api/v1/auth/login — returns the decoded JSON body (success/error/token/...)
sub login ($self, $email, $password) {
    my $tx = $self->_ua->post(
        $self->base_url . '/api/v1/auth/login',
        json => { email => $email, password => $password },
    );
    return $self->_decode($tx);
}

# GET /api/v1/auth/introspect with the given bearer token — returns the
# decoded JSON body plus a `_status` key with the HTTP status code.
sub introspect ($self, $jwt) {
    my $tx = $self->_ua->get(
        $self->base_url . '/api/v1/auth/introspect',
        { Authorization => "Bearer $jwt" },
    );
    return $self->_decode($tx);
}

# POST /api/v1/auth/refresh, passing the refresh token as the
# `homelab-token` cookie (the shape homelab-api expects) — returns the
# decoded JSON body (success/token/refresh_token/expires_in/...).
sub refresh ($self, $refresh_token) {
    my $tx = $self->_ua->post(
        $self->base_url . '/api/v1/auth/refresh',
        { Cookie => "homelab-token=$refresh_token" },
    );
    return $self->_decode($tx);
}

# POST /api/v1/auth/logout, passing the refresh token as the
# `homelab-token` cookie — revokes it server-side. Best-effort; callers
# should not block on this failing.
sub revoke ($self, $refresh_token) {
    my $tx = $self->_ua->post(
        $self->base_url . '/api/v1/auth/logout',
        { Cookie => "homelab-token=$refresh_token" },
    );
    return $self->_decode($tx);
}

sub _decode ($self, $tx) {
    my $res = $tx->result;
    if (my $err = $tx->error) {
        return { success => 0, error => $err->{message} // 'connection error', _status => $res ? $res->code : 0 }
            unless $res;
    }
    my $body = $res->body;
    return { success => 0, error => 'empty response', _status => $res->code } unless $body;
    my $data = eval { decode_json($body) };
    return { success => 0, error => "bad JSON: $@", _status => $res->code } if $@;
    $data->{_status} = $res->code;
    return $data;
}

1;
