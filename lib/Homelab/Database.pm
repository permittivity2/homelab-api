package Homelab::Database;

use strict;
use warnings;
use Mojo::Pg;
use Mojo::Promise;
use Carp qw(croak);

sub new {
    my ($class, $config) = @_;
    my $cfg = $config->{database};

    my $pg = Mojo::Pg->new(sprintf(
        'postgresql://%s:%s@%s:%s/%s',
        $cfg->{user}, $cfg->{password},
        $cfg->{host}, $cfg->{port}, $cfg->{name}
    ));

    return bless { pg => $pg }, $class;
}

sub ping {
    my ($self) = @_;
    my $ok = eval { $self->{pg}->db->ping };
    return ($@ || !$ok) ? 0 : 1;
}

sub query {
    my ($self, $sql, @params) = @_;
    return $self->{pg}->db->query($sql, @params);
}

sub query_row {
    my ($self, $sql, @params) = @_;
    return $self->{pg}->db->query($sql, @params)->hash;
}

sub query_rows {
    my ($self, $sql, @params) = @_;
    return $self->{pg}->db->query($sql, @params)->hashes->to_array;
}

sub query_p {
    my ($self, $sql, @params) = @_;
    return $self->{pg}->db->query_p($sql, @params);
}

sub query_row_p {
    my ($self, $sql, @params) = @_;
    return $self->{pg}->db->query_p($sql, @params)
        ->then(sub { shift->hash });
}

sub query_rows_p {
    my ($self, $sql, @params) = @_;
    return $self->{pg}->db->query_p($sql, @params)
        ->then(sub { shift->hashes->to_array });
}

1;
