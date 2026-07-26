package Homelab::RateLimit;

use strict;
use warnings;

my $_gc_counter = 0;

sub new {
    my ($class, $db, %opts) = @_;
    my $self = {
        db           => $db,
        max_attempts => $opts{max_attempts} // 5,
        window       => $opts{window} // 900,  # 15 minutes in seconds
    };
    return bless $self, $class;
}

sub check {
    my ($self, $email) = @_;
    return 1 unless $email;

    my $email_lower = lc($email);

    my $result = $self->{db}->query_row(
        'SELECT COUNT(*) as count FROM api.rate_limits '
        . 'WHERE LOWER(email) = LOWER($1) AND attempt_at > NOW() - ($2 * INTERVAL \'1 second\')',
        $email_lower,
        $self->{window}
    );

    my $count = $result ? $result->{count} : 0;

    if ($count >= $self->{max_attempts}) {
        return 0;  # Blocked
    }

    return 1;  # Not blocked
}

sub record_attempt {
    my ($self, $email) = @_;
    return unless $email;

    my $email_lower = lc($email);

    $self->{db}->query(
        'INSERT INTO api.rate_limits (email, attempt_at) VALUES (LOWER($1), NOW())',
        $email_lower
    );

    $_gc_counter++;
    $self->_gc() if $_gc_counter % 50 == 0;
}

sub clear {
    my ($self, $email) = @_;
    return unless $email;

    my $email_lower = lc($email);

    $self->{db}->query(
        'DELETE FROM api.rate_limits WHERE LOWER(email) = LOWER($1)',
        $email_lower
    );
}

sub _gc {
    my ($self) = @_;

    $self->{db}->query(
        'DELETE FROM api.rate_limits WHERE attempt_at < NOW() - ($1 * INTERVAL \'1 second\')',
        $self->{window}
    );
}

1;
