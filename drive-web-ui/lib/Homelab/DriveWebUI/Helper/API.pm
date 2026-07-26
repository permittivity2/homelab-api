package Homelab::DriveWebUI::Helper::API;

use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);

has 'base_url'      => 'https://api.example.com';
has 'jwt';
has 'refresh_token';
has 'on_refresh';   # coderef($new_jwt, $new_refresh_token) — updates session
has '_ua' => sub {
    Mojo::UserAgent->new(
        max_response_size    => 0,     # no limit — large file downloads
        request_timeout      => 0,     # no total timeout — large uploads can take hours
        connect_timeout      => 10,
        inactivity_timeout   => 0,     # no inactivity timeout — large uploads have gaps
    );
};

sub get ($self, $path) {
    return $self->_request('GET', $path);
}

sub post ($self, $path, $body) {
    return $self->_request('POST', $path, json => $body);
}

sub post_form ($self, $path, $form) {
    return $self->_request('POST', $path, form => $form);
}

sub patch ($self, $path, $body) {
    return $self->_request('PATCH', $path, json => $body);
}

sub del ($self, $path) {
    return $self->_request('DELETE', $path);
}

# Returns the raw Mojo::Transaction for streaming (e.g. file downloads)
sub get_tx ($self, $path) {
    return $self->_ua->get($self->base_url . $path, $self->_auth_headers);
}

sub _request ($self, $method, $path, @opts) {
    my $res = $self->_do_request($method, $path, @opts);

    # On 401, attempt a silent token refresh and retry once
    if (($res->{_status} // 0) == 401 && $self->refresh_token && $self->on_refresh) {
        if ($self->_try_refresh()) {
            $res = $self->_do_request($method, $path, @opts);
        }
    }

    return $res;
}

sub _do_request ($self, $method, $path, @opts) {
    my $url = $self->base_url . $path;
    my $ua  = $self->_ua;
    my $tx;

    if ($method eq 'GET') {
        $tx = $ua->get($url, $self->_auth_headers);
    } elsif ($method eq 'DELETE') {
        $tx = $ua->delete($url, $self->_auth_headers);
    } elsif ($method eq 'PATCH') {
        $tx = $ua->patch($url, $self->_auth_headers, @opts);
    } else {
        $tx = $ua->post($url, $self->_auth_headers, @opts);
    }

    return $self->_decode($tx);
}

sub _try_refresh ($self) {
    my $ua  = Mojo::UserAgent->new(connect_timeout => 10);
    my $url = $self->base_url . '/api/v1/auth/refresh';
    my $tx  = $ua->post($url, { Cookie => 'homelab-token=' . $self->refresh_token });
    my $data = eval { $tx->result->json } // {};
    return 0 unless $data->{success};

    $self->jwt($data->{token});
    $self->refresh_token($data->{refresh_token});
    $self->on_refresh->($data->{token}, $data->{refresh_token});
    return 1;
}

sub _auth_headers ($self) {
    my $jwt = $self->jwt;
    return {} unless $jwt;
    return { Authorization => "Bearer $jwt" };
}

sub _decode ($self, $tx) {
    my $res = $tx->result;
    if (my $err = $tx->error) {
        return { success => 0, error => $err->{message} // 'connection error' }
            unless $res;
    }
    my $body = $res->body;
    return { success => 0, error => 'empty response', code => $res->code } unless $body;
    my $data = eval { decode_json($body) };
    return { success => 0, error => "bad JSON: $@", code => $res->code } if $@;
    $data->{_status} = $res->code;
    return $data;
}

1;
