package Homelab::Utils::JWT;

use strict;
use warnings;
use Exporter qw(import);
use Crypt::JWT qw(encode_jwt decode_jwt);
use Carp qw(croak);
use Time::HiRes qw(time);

our @EXPORT_OK = qw(generate_token verify_token generate_refresh_token);

sub generate_token {
    my ($config, $email, $expires_in) = @_;
    $expires_in ||= $config->{jwt}{expires_in} || 1800;

    my $now = time;
    my $exp = int($now) + $expires_in;

    my $token = encode_jwt(
        payload => {
            email => $email,
            iat   => int($now),
            exp   => $exp,
        },
        key    => $config->{jwt}{secret},
        alg    => $config->{jwt}{algorithm} || 'HS256',
    );

    return ($token, $expires_in);
}

sub verify_token {
    my ($config, $token) = @_;

    return undef unless $token;

    my $payload;
    eval {
        $payload = decode_jwt(
            token => $token,
            key   => $config->{jwt}{secret},
            alg   => $config->{jwt}{algorithm} || 'HS256',
        );
    };

    return $@ ? undef : $payload;
}

sub generate_refresh_token {
    return _random_token(64);
}

sub _random_token {
    my ($length) = @_;
    my @chars = ('a'..'z', 'A'..'Z', '0'..'9');
    my $token = '';
    for (1..$length) {
        $token .= $chars[int(rand(@chars))];
    }
    return $token;
}

1;
