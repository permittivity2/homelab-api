package Homelab::Utils::Password;

use strict;
use warnings;
use Exporter qw(import);
use Crypt::Argon2 qw(argon2id_pass argon2id_verify);

our @EXPORT_OK = qw(verify_dovecot_password);

sub verify_dovecot_password {
    my ($plaintext, $hash) = @_;

    return 0 unless $plaintext && $hash;

    if ($hash =~ /^\$6\$/) {
        return _verify_sha512_crypt($plaintext, $hash);
    }

    return 0;
}

sub _verify_sha512_crypt {
    my ($plaintext, $hash) = @_;

    my $computed = crypt($plaintext, $hash);
    return $computed eq $hash ? 1 : 0;
}

sub hash_password {
    my ($plaintext) = @_;
    return argon2id_pass($plaintext);
}

sub verify_password {
    my ($plaintext, $hash) = @_;
    return argon2id_verify($hash, $plaintext);
}

1;
