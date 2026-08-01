package Homelab::DriveWebUI::Helper::SSO;

use Mojo::Base -base, -signatures;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json);

has 'base_url'      => 'https://login.example.com';
has 'client_id'     => 'drive';
has 'client_secret';
has 'redirect_uri';
has '_ua' => sub {
    Mojo::UserAgent->new(connect_timeout => 10, request_timeout => 15);
};

# Builds the URL to send the browser to in order to start (or silently
# resume) an SSO login for this client.
sub authorize_url ($self, $state) {
    my $url = Mojo::URL->new($self->base_url . '/oauth/authorize');
    $url->query->append(
        response_type => 'code',
        client_id     => $self->client_id,
        redirect_uri  => $self->redirect_uri,
        state         => $state,
    );
    return $url;
}

# Builds the SSO single-logout URL — clears the shared IdP session and
# redirects back to $redirect_uri (which must match this client's own
# registered redirect_uri's origin, or homelab-sso-ui falls back to its
# own generic logged-out page instead).
sub logout_url ($self, $redirect_uri) {
    my $url = Mojo::URL->new($self->base_url . '/logout');
    $url->query->append(redirect_uri => $redirect_uri);
    return $url;
}

# POST /oauth/token — exchanges an authorization code for a token. Returns
# the decoded JSON body (access_token/refresh_token/expires_in/...).
sub exchange_code ($self, $code) {
    my $tx = $self->_ua->post(
        $self->base_url . '/oauth/token',
        form => {
            grant_type    => 'authorization_code',
            code          => $code,
            client_id     => $self->client_id,
            client_secret => $self->client_secret,
            redirect_uri  => $self->redirect_uri,
        },
    );
    return $self->_decode($tx);
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
