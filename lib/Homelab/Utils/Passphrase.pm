package Homelab::Utils::Passphrase;

use strict;
use warnings;
use Exporter qw(import);
use Crypt::URandom qw(urandom);

our @EXPORT_OK = qw(generate_passphrase);

our $MIN_TOTAL_LEN  = 12;
our $MAX_TOTAL_LEN  = 20;
our $MIN_WORD_LEN   = 3;
our $MAX_WORD_LEN   = 8;
our $SEPARATOR      = '-';
our $DEFAULT_WORDLIST = '/usr/share/dict/american-english';

my %_buckets_by_path;
my %_valid_pairs_by_path;

# Cryptographically-uniform random integer in [0, $max), via rejection
# sampling over urandom() bytes — avoids the modulo bias a plain
# `unpack('N', urandom(4)) % $max` would introduce.
sub _random_index {
    my ($max) = @_;
    die "max must be positive" unless $max && $max > 0;

    my $limit = int(2**32 / $max) * $max;
    while (1) {
        my $n = unpack('N', urandom(4));
        return $n % $max if $n < $limit;
    }
}

sub _random_element {
    my ($arrayref) = @_;
    return $arrayref->[ _random_index(scalar @$arrayref) ];
}

sub _load_buckets {
    my ($wordlist_path) = @_;

    return $_buckets_by_path{$wordlist_path} if $_buckets_by_path{$wordlist_path};

    my %buckets;
    open my $fh, '<', $wordlist_path
        or die "Cannot open wordlist $wordlist_path: $!";
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /^[a-z]{$MIN_WORD_LEN,$MAX_WORD_LEN}$/;
        push @{ $buckets{ length($line) } }, $line;
    }
    close $fh;

    $_buckets_by_path{$wordlist_path} = \%buckets;
    return \%buckets;
}

sub _valid_pairs {
    my ($wordlist_path) = @_;

    return $_valid_pairs_by_path{$wordlist_path} if $_valid_pairs_by_path{$wordlist_path};

    my $buckets = _load_buckets($wordlist_path);
    my $sep_len = length($SEPARATOR);
    my $min_sum = $MIN_TOTAL_LEN - $sep_len;
    my $max_sum = $MAX_TOTAL_LEN - $sep_len;

    my @pairs;
    for my $len1 ($MIN_WORD_LEN .. $MAX_WORD_LEN) {
        next unless $buckets->{$len1} && @{ $buckets->{$len1} };
        for my $len2 ($MIN_WORD_LEN .. $MAX_WORD_LEN) {
            next unless $buckets->{$len2} && @{ $buckets->{$len2} };
            my $sum = $len1 + $len2;
            push @pairs, [ $len1, $len2 ] if $sum >= $min_sum && $sum <= $max_sum;
        }
    }

    die "No valid word-length combination found in $wordlist_path for the configured length constraints"
        unless @pairs;

    $_valid_pairs_by_path{$wordlist_path} = \@pairs;
    return \@pairs;
}

# Generates a passphrase of exactly two dictionary words joined by
# $SEPARATOR, guaranteed on the first attempt (no retry loop) to have a
# total length in [$MIN_TOTAL_LEN, $MAX_TOTAL_LEN], each word at least
# $MIN_WORD_LEN characters. All randomness sourced from Crypt::URandom
# (kernel CSPRNG) — this is the entire security property of the admin
# password-reset flow that calls this.
sub generate_passphrase {
    my (%opts) = @_;
    my $wordlist_path = $opts{wordlist_path} || $DEFAULT_WORDLIST;

    my $buckets = _load_buckets($wordlist_path);
    my $pairs   = _valid_pairs($wordlist_path);

    my ($len1, $len2) = @{ _random_element($pairs) };
    my $word1 = _random_element($buckets->{$len1});
    my $word2 = _random_element($buckets->{$len2});

    my $passphrase = "$word1$SEPARATOR$word2";

    die "Generated passphrase '$passphrase' violates length constraints (internal bug)"
        unless length($passphrase) >= $MIN_TOTAL_LEN && length($passphrase) <= $MAX_TOTAL_LEN;

    return $passphrase;
}

1;
